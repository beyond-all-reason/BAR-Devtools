r"""WSL-side BAR-Devtools sync daemon (Phase 3, architecture iv =
`wsl-watchdog-mntc`).

Watches Devtools checkout subtrees on the WSL ext4 side using native inotify
(via the `watchdog` Observer) and mirrors changes through /mnt/c into the
Windows-local NTFS data dir the engine reads from.

Why WSL-side instead of Windows-side: the Phase 1 probe's prior architecture
(iii) ran the watcher on Windows reading WSL paths over `\\wsl.localhost\…`
(Plan 9). Plan 9 does NOT deliver inotify across the boundary, so that
watcher silently degraded to PollingObserver semantics regardless of how
it advertised itself. Re-running the probe with the watcher on the WSL side
(arm iv) measured a **97.6 ms median / 160 ms p95 / 181 ms max** sustained
edit-loop latency at 5 touches/sec, vs. Windows-side at 109/179/215 -- with
the additional benefit that detection is real fsevents instead of polling.
See bar-design-docs/bifurcated_types/dev_setup_restructured.md → Tests 4-5.

Invocation (typically via scripts/sync.sh from WSL):

    python3 scripts/sync.py \
        --pair <linux-source>::<linux-dst> \
        --pair ... \
        [--log <path>] [--polling]

Sources are POSIX paths on the WSL side (`/home/<u>/code/...`); destinations
are POSIX paths under `/mnt/c/...` so the watcher writes to NTFS via the
9P-mediated drvfs mount. Each --pair gets its own watchdog scheduler; one
process aggregates them so the engine sees changes from all the repos
cohesively.

Inode-stable writes (--inplace equivalent): we open the destination for
write+truncate and stream bytes in. We never rename a temp file over the
target, because the engine mmaps Lua sources and a rename would invalidate
the mmap mid-frame.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Iterable

try:
    from watchdog.events import FileSystemEventHandler
    from watchdog.observers import Observer
    from watchdog.observers.polling import PollingObserver
except ImportError as exc:
    sys.stderr.write(
        "watchdog not installed. On Ubuntu/WSL2 install with:\n"
        "    sudo apt-get install -y python3-watchdog\n"
        "Or re-run `just setup::init`, which prompts for the same install.\n"
    )
    raise SystemExit(1) from exc


log = logging.getLogger("bar-launch.sync")


def _copy_inplace(src: Path, dst: Path) -> None:
    """Mirror src -> dst with in-place write (no rename, no inode rotation).

    Mirrors verbatim: spring's archive scanner accepts the literal "$VERSION"
    placeholder in modinfo.lua and registers the archive as
    "<name> $VERSION", which is what chobby's byar-dev gameConfig expects
    (and what Linux symlinks already produce). An earlier revision of this
    file substituted "$VERSION" -> "local" here, on the mistaken premise
    that the scanner skipped it; that broke the byar-dev path on WSL2 by
    diverging from the Linux flow's archive name.
    """
    dst.parent.mkdir(parents=True, exist_ok=True)
    # shutil.copyfile opens dst with 'wb' which truncates and writes in
    # place. That's what we want: an mmaped reader on dst sees the file
    # change content, not a new inode.
    shutil.copyfile(src, dst)
    # Preserve mtime so timestamp-based reload heuristics work.
    try:
        st = src.stat()
        os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns))
    except OSError:
        pass


# Subtrees that the engine never reads but cost a lot to sync. .git pack
# files are also stored read-only on disk, which makes them un-overwritable
# on subsequent cold copies (Errno 13 storms in the log).
_SKIP_DIRS = frozenset({".git", ".github", "__pycache__", "node_modules"})


def _is_skipped(rel: Path) -> bool:
    return any(part in _SKIP_DIRS for part in rel.parts)


def _state_dir() -> Path:
    """Per-user persistent state. Lives on Linux ext4 (NOT /mnt/c) so
    Watchman's clock tokens and our per-pair state survive across daemon
    restarts without paying drvfs costs every read."""
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    d = Path(base) / "bar-devtools"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _pair_state_path(src_root: Path, dst_root: Path) -> Path:
    """One state file per (src, dst) pair. Hash the pair so multiple
    Devtools checkouts on the same machine don't collide."""
    h = hashlib.sha1(f"{src_root}::{dst_root}".encode()).hexdigest()[:12]
    return _state_dir() / f"sync-state-{h}.json"


def _watchman(args: list[str], timeout: float = 60.0) -> dict:
    """Run watchman with -j (JSON over stdin), return parsed response."""
    proc = subprocess.run(
        ["watchman", "-j", "--no-pretty"],
        input=json.dumps(args),
        capture_output=True, text=True, timeout=timeout, check=True,
    )
    return json.loads(proc.stdout)


def _cold_copy(src_root: Path, dst_root: Path) -> None:
    """Mirror src_root -> dst_root using Watchman to skip the rsync
    stat-walk on unchanged subtrees. First call for a (src, dst) pair
    seeds dst with full rsync; subsequent calls use `watchman since
    <clock>` + rsync --files-from for only the changed files.

    --inplace preserves the engine's mmap-stable inode contract: rsync
    overwrites in place rather than tempfile + rename, so a Lua source
    the engine has mmaped doesn't change inode under it."""
    dst_root.mkdir(parents=True, exist_ok=True)
    _cold_copy_via_watchman(src_root, dst_root)


def _cold_copy_full_rsync(src_root: Path, dst_root: Path) -> None:
    """The unconditional path: rsync everything, skipping by size+mtime.
    Always correct, slow on /mnt/c due to per-file stat round-trips."""
    excludes: list[str] = []
    for d in _SKIP_DIRS:
        excludes += ["--exclude", f"/{d}", "--exclude", f"**/{d}"]
    cmd = ["rsync", "-a", "--delete", "--inplace",
           *excludes,
           f"{src_root}/", f"{dst_root}/"]
    try:
        subprocess.run(cmd, check=True)
    except FileNotFoundError as exc:
        raise SystemExit(
            "rsync not found on PATH. Install via: sudo apt-get install -y rsync"
        ) from exc
    except subprocess.CalledProcessError as exc:
        # Most common cause for this codebase: Windows holds open handles
        # on engine DLLs, so rsync writes from Linux through drvfs hit
        # EACCES. Other causes are unreadable source files (rare), or
        # rsync failing to delete a stale dst entry (also rare). Always
        # survivable, but the user should know what to check.
        if exc.returncode == 23:
            log.warning(
                "rsync exit 23 (some files not transferred) for %s -> %s. "
                "Most likely cause: Windows is holding open handles on the "
                "destination files. Check whether spring.exe or the BAR "
                "launcher is running:  just bar::stop  then re-run.",
                src_root, dst_root)
        else:
            log.warning("rsync exit %s for %s -> %s -- cold copy may be partial",
                        exc.returncode, src_root, dst_root)


def _cold_copy_via_watchman(src_root: Path, dst_root: Path) -> None:
    """Watchman-driven incremental cold copy. Called from _cold_copy on
    the happy path; the caller catches our exceptions and falls back to
    full rsync. Raises on any error so the fallback is unambiguous."""
    state_path = _pair_state_path(src_root, dst_root)

    # `watch-project` is idempotent and returns the watch root (which may
    # be an ancestor of src_root if a parent dir is already watched). The
    # `relative_path` it returns scopes our queries to our subtree.
    watch_resp = _watchman(["watch-project", str(src_root)])
    watch_root = watch_resp["watch"]
    relative_path = watch_resp.get("relative_path")

    state = _load_pair_state(state_path)
    same_pair = (state.get("src") == str(src_root)
                 and state.get("dst") == str(dst_root)
                 and state.get("watch_root") == watch_root)

    if not same_pair or not state.get("clock"):
        # First run for this (src, dst) pair, or pair changed: full rsync,
        # capture clock at the END so any concurrent edits during rsync
        # show up as "changed since clock" on the next run.
        _cold_copy_full_rsync(src_root, dst_root)
        clock = _watchman(["clock", watch_root])["clock"]
        _save_pair_state(state_path, src_root, dst_root, watch_root, clock)
        log.info("watchman: initial clock recorded (%s) for %s", clock, src_root)
        return

    # Incremental path: ask "what changed since the saved clock?"
    query: dict = {
        "since": state["clock"],
        "fields": ["name", "exists"],
    }
    if relative_path:
        query["relative_root"] = relative_path

    resp = _watchman(["query", watch_root, query])

    files = resp.get("files", [])
    new_clock = resp["clock"]

    changed: list[str] = []
    deleted: list[str] = []
    for f in files:
        name = f["name"]
        # Skip subtrees we never sync. Match against any path component
        # so '.git/HEAD' is filtered the same as 'foo/.git/HEAD'.
        rel_parts = Path(name).parts
        if any(p in _SKIP_DIRS for p in rel_parts):
            continue
        if f.get("exists", True):
            changed.append(name)
        else:
            deleted.append(name)

    if changed:
        # rsync ONLY the changed files. --files-from reads paths relative
        # to src_root (when src_root is the SRC arg), one per line.
        cmd = ["rsync", "-a", "--inplace", "--files-from=-",
               f"{src_root}/", f"{dst_root}/"]
        subprocess.run(cmd, input="\n".join(changed) + "\n",
                       text=True, check=True)

    for rel in deleted:
        target = dst_root / rel
        try:
            target.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            log.warning("could not delete dst %s: %s", target, exc)

    _save_pair_state(state_path, src_root, dst_root, watch_root, new_clock)
    log.info("watchman incremental: %d changed, %d deleted (%s)",
             len(changed), len(deleted), src_root)


def _load_pair_state(path: Path) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_pair_state(path: Path, src_root: Path, dst_root: Path,
                     watch_root: str, clock: str) -> None:
    """Atomic-rename write, fsync'd. State file integrity matters because
    a corrupted clock token reads as 'unknown changeset' on next start
    and we'd silently full-rsync forever -- annoying but recoverable."""
    payload = json.dumps({
        "src": str(src_root),
        "dst": str(dst_root),
        "watch_root": watch_root,
        "clock": clock,
    }, indent=2)
    tmp = path.with_suffix(f".tmp.{os.getpid()}")
    with open(tmp, "w") as f:
        f.write(payload)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


class _MirrorHandler(FileSystemEventHandler):
    """Translate FS events on src_root into mirrored writes under dst_root.

    We re-resolve paths relative to src_root for every event rather than
    trusting the event payload's absolute path -- watchdog's normalization
    of UNC paths is fiddly across Python builds.
    """

    def __init__(self, src_root: Path, dst_root: Path) -> None:
        self._src = src_root
        self._dst = dst_root
        # Coalesce rapid-fire events on the same path -- editors save via
        # multiple syscalls and we'd otherwise copy 3x per save.
        self._pending: dict[str, float] = {}
        self._lock = threading.Lock()

    def _enqueue(self, path: str) -> None:
        with self._lock:
            self._pending[path] = time.monotonic()

    def on_modified(self, event) -> None:
        if event.is_directory:
            return
        self._enqueue(event.src_path)

    def on_created(self, event) -> None:
        if event.is_directory:
            return
        self._enqueue(event.src_path)

    def on_moved(self, event) -> None:
        if event.is_directory:
            return
        # Treat moves as create-at-destination + delete-at-source.
        self._delete_at(event.src_path)
        self._enqueue(event.dest_path)

    def on_deleted(self, event) -> None:
        if event.is_directory:
            return
        self._delete_at(event.src_path)

    def _delete_at(self, src_path: str) -> None:
        try:
            rel = Path(src_path).resolve().relative_to(self._src.resolve())
        except (ValueError, OSError):
            return
        dst = self._dst / rel
        try:
            dst.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            # Same root-cause family as mirror failures above: Windows
            # holding the dst open. We don't refuse to continue -- the
            # next save of the same file will overwrite, which is the
            # user's natural recovery anyway.
            log.warning(
                "could not delete dst %s (Windows may hold an open handle; "
                "next save will overwrite anyway): %s", rel, exc)

    def drain(self, max_age_seconds: float = 0.10) -> None:
        """Flush pending events older than max_age_seconds."""
        now = time.monotonic()
        ready: list[str] = []
        with self._lock:
            for path, ts in list(self._pending.items()):
                if now - ts >= max_age_seconds:
                    ready.append(path)
                    del self._pending[path]
        for src_path in ready:
            try:
                src = Path(src_path)
                if not src.is_file():
                    continue
                rel = src.resolve().relative_to(self._src.resolve())
                _copy_inplace(src, self._dst / rel)
                # Log at INFO so `just bar::sync-logs` shows propagation
                # events live -- a silent log is hard to distinguish from
                # a broken watcher when nothing seems to be syncing. The
                # 100 ms coalesce in self._pending keeps this from
                # spamming under burst writes.
                log.info("mirrored %s", rel)
            except ValueError as exc:
                # relative_to() raised -- the event path didn't resolve
                # under self._src. Almost always a symlink-target change
                # mid-run; the daemon is now watching stale inodes and
                # the contributor needs a restart to pick up the new tree.
                log.warning(
                    "skipping %s: not under watched root %s (symlink may "
                    "have been re-pointed; consider 'just link::create <name>' "
                    "and restart the sync daemon)", src_path, self._src)
            except OSError as exc:
                # Most common failure here on /mnt/c targets: Windows is
                # holding the dst file open (engine DLL race, antivirus
                # scan, antivirus controlled-folder-access policy).
                log.warning(
                    "mirror failed for %s: %s. If this is an engine DLL, "
                    "stop spring.exe / BAR launcher (just bar::stop) and "
                    "re-trigger. If it's a Lua source, check whether the "
                    "destination is writable from WSL.", src_path, exc)


def _parse_pairs(pairs: Iterable[str]) -> list[tuple[Path, Path]]:
    parsed: list[tuple[Path, Path]] = []
    for raw in pairs:
        # UNC paths contain ':' (after the drive letter when normalized) but
        # the source side is always a UNC \\wsl$\..., so split on the LAST
        # ':' that follows a path separator. Simpler: use '::' as the
        # separator in the CLI, but keep ':' for human ergonomics by
        # splitting on the first occurrence after position 3.
        sep = raw.find("::")
        if sep < 0:
            raise SystemExit(f"--pair must be SRC::DST, got: {raw!r}")
        src = Path(raw[:sep])
        dst = Path(raw[sep + 2 :])
        if not src.exists():
            log.warning("source missing (will retry on event): %s", src)
        parsed.append((src, dst))
    return parsed


def _setup_logging(log_path: Path | None) -> None:
    # When --log is provided we ONLY install the FileHandler. sync.sh runs
    # the daemon with `2>>"$LOG_FILE"`, so adding a StreamHandler(stderr)
    # would write every line twice -- once via stderr -> file redirect,
    # once via FileHandler. Foreground / interactive use (no --log) gets
    # the stderr handler so the user sees output in their terminal.
    handlers: list[logging.Handler] = []
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.FileHandler(str(log_path), encoding="utf-8"))
    else:
        handlers.append(logging.StreamHandler(sys.stderr))
    logging.basicConfig(
        level=os.environ.get("BAR_SYNC_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=handlers,
        force=True,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="bar-launch-sync",
        description="Mirror WSL Devtools checkouts to a Windows NTFS data dir.",
    )
    parser.add_argument(
        "--pair",
        action="append",
        required=True,
        metavar="SRC::DST",
        help="Source (WSL ext4 path) and destination (POSIX form of /mnt/c/... "
             "or any NTFS path), separated by '::'. Repeatable.",
    )
    parser.add_argument("--log", type=Path, help="Append log lines to this file in addition to stderr.")
    parser.add_argument(
        "--polling",
        action="store_true",
        help="Force PollingObserver instead of native inotify. "
        "Use if inotify watch limits are exceeded or events stop propagating.",
    )
    parser.add_argument(
        "--cold-copy",
        action="store_true",
        help="Run a one-shot cold mirror of every pair, then exit. No watching.",
    )
    parser.add_argument(
        "--ready-file",
        type=Path,
        help="After cold copy and watcher startup, touch this file. Used by "
        "scripts/sync.sh to gate `bar-launch` invocation on a quiesced "
        "initial mirror.",
    )
    args = parser.parse_args(argv)

    _setup_logging(args.log)

    pairs = _parse_pairs(args.pair)

    log.info("cold copy: %d pair(s)", len(pairs))
    for src, dst in pairs:
        if not src.exists():
            log.warning("skipping cold copy: %s does not exist", src)
            continue
        t0 = time.monotonic()
        _cold_copy(src, dst)
        log.info("  %s -> %s (rsync, %.1fs)", src, dst, time.monotonic() - t0)

    if args.cold_copy:
        if args.ready_file is not None:
            args.ready_file.parent.mkdir(parents=True, exist_ok=True)
            args.ready_file.touch()
        return 0

    observer_cls = PollingObserver if args.polling else Observer
    observer = observer_cls()
    handlers: list[_MirrorHandler] = []
    for src, dst in pairs:
        if not src.exists():
            log.warning("skipping watch: %s does not exist", src)
            continue
        handler = _MirrorHandler(src.resolve(), dst.resolve())
        observer.schedule(handler, str(src), recursive=True)
        handlers.append(handler)

    observer.start()
    # Surface the inotify watch limit at startup. The Observer registers
    # one watch per directory, recursively; on Ubuntu the default is 8192
    # which is well under BAR's per-tree directory count, and watches that
    # exceed the limit fail silently inside the inotify backend. If events
    # never fire for files in deep subtrees, this is the first thing to
    # check.
    try:
        with open("/proc/sys/fs/inotify/max_user_watches") as f:
            limit = int(f.read().strip())
        log.info("watcher up; %d handler(s) scheduled (fs.inotify.max_user_watches=%d)",
                 len(handlers), limit)
        if limit < 131072:
            log.warning(
                "fs.inotify.max_user_watches=%d is low for BAR-sized trees; "
                "events for deep subtrees may not fire. Bump persistently:\n"
                "  echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/99-bar-devtools.conf\n"
                "  sudo sysctl -p /etc/sysctl.d/99-bar-devtools.conf", limit)
    except OSError:
        log.info("watcher up; %d handler(s) scheduled", len(handlers))

    if args.ready_file is not None:
        args.ready_file.parent.mkdir(parents=True, exist_ok=True)
        args.ready_file.touch()

    stop = threading.Event()

    # Per-signal explanation so a user reading the log knows whether they
    # caused the shutdown (Ctrl-C / `bar::stop`) or something else did
    # (HUP from terminal close, OOM killer, etc.). "signal 15" tells
    # nobody anything.
    _SIGNAL_REASONS = {
        signal.SIGINT:  "SIGINT (Ctrl-C in the foreground terminal)",
        signal.SIGTERM: "SIGTERM (likely 'just bar::stop' or 'sync.sh stop')",
        signal.SIGHUP:  "SIGHUP (controlling terminal closed)",
    }

    def _on_signal(signum, _frame):
        reason = _SIGNAL_REASONS.get(signum, f"signal {signum}")
        log.info("received %s -- draining pending events and exiting", reason)
        stop.set()

    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)
    # SIGHUP is what nohup is supposed to mask; surfacing it just in case
    # a non-nohup launch path inherits it from the controlling terminal.
    try:
        signal.signal(signal.SIGHUP, _on_signal)
    except (AttributeError, ValueError):
        pass

    try:
        while not stop.is_set():
            for handler in handlers:
                handler.drain()
            stop.wait(0.05)
    finally:
        observer.stop()
        observer.join(timeout=5)
        # Final drain so events that arrived during teardown still get out.
        for handler in handlers:
            handler.drain(max_age_seconds=0.0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
