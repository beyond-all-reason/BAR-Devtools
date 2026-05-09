r"""WSL-side BAR-Devtools sync daemon (Phase 3, architecture iv).

Runs *inside* the bar-sync distrobox container. Watches Devtools checkout
subtrees (Beyond-All-Reason, BYAR-Chobby, RecoilEngine install/) on the
WSL ext4 side via watchman subscriptions and mirrors changes through
/mnt/c into the Windows-local NTFS data dir the engine reads from.

Why WSL-side instead of Windows-side: the Phase 1 probe's prior architecture
ran the watcher on Windows reading WSL paths over `\\wsl.localhost\…`
(Plan 9). Plan 9 does NOT deliver inotify across the boundary, so that
watcher silently degraded to PollingObserver semantics regardless of how
it advertised itself. Re-running the probe with the watcher on the WSL side
measured a **97.6 ms median / 160 ms p95 / 181 ms max** sustained edit-loop
latency at 5 touches/sec, vs. Windows-side at 109/179/215 -- with the
additional benefit that detection is real fsevents instead of polling.

Why watchman + pywatchman (not watchdog/inotify directly): the prior
implementation maintained two parallel filesystem watchers -- watchdog
for live events and watchman only for cold-copy delta. That dual-stack
caused a confusing edge case where a fresh watchman daemon (after WSL
killed the previous one) replied to "since <old-clock>" with the entire
tree (`is_fresh_instance: true`), making cold-copy log "19,301 files
changed" with no actual edits. Watchman is designed to be the single
source of truth for "what changed in this directory ever," so we
collapse onto it: subscriptions stream events and the same clock token
also drives cross-restart deltas. `is_fresh_instance: true` becomes a
clearly-named log line, not a mystery 80s rsync.

Invocation (always via scripts/sync.sh, which `distrobox enter`s bar-sync):

    python3 scripts/sync.py \
        --pair <linux-source>::<linux-dst> \
        --pair ... \
        [--log <path>] [--cold-copy] [--ready-file <path>]

Sources are POSIX paths on the WSL side (`/home/<u>/code/...`); destinations
are POSIX paths under `/mnt/c/...` so the watcher writes to NTFS via the
9P-mediated drvfs mount.

Inode-stable writes: we open the destination for write+truncate and stream
bytes in. We never rename a temp file over the target, because the engine
mmaps Lua sources and a rename would invalidate the mmap mid-frame.
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
    import pywatchman
except ImportError as exc:
    sys.stderr.write(
        "pywatchman not installed. This script is meant to run inside the\n"
        "bar-sync distrobox container -- see docker/sync.Containerfile.\n"
        "If you're invoking it directly, build the container with:\n"
        "    just setup::distrobox\n"
    )
    raise SystemExit(1) from exc


log = logging.getLogger("bar-launch.sync")


def _copy_inplace(src: Path, dst: Path) -> None:
    """Mirror src -> dst with in-place write (no rename, no inode rotation).

    Mirrors verbatim: spring's archive scanner accepts the literal "$VERSION"
    placeholder in modinfo.lua and registers the archive as
    "<name> $VERSION", which is what chobby's byar-dev gameConfig expects
    (and what Linux symlinks already produce).
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
    Watchman's clock tokens survive across daemon restarts without
    paying drvfs costs every read."""
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    d = Path(base) / "bar-devtools"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _pair_state_path(src_root: Path, dst_root: Path) -> Path:
    """One state file per (src, dst) pair. Hash the pair so multiple
    Devtools checkouts on the same machine don't collide."""
    h = hashlib.sha1(f"{src_root}::{dst_root}".encode()).hexdigest()[:12]
    return _state_dir() / f"sync-state-{h}.json"


def _load_pair_state(path: Path) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_pair_state(path: Path, src_root: Path, dst_root: Path,
                     clock: str) -> None:
    """Atomic-rename write, fsync'd. State file integrity matters because
    a corrupted clock token reads as is_fresh_instance on next start and
    we'd needlessly re-seed -- annoying but recoverable."""
    payload = json.dumps({
        "src": str(src_root),
        "dst": str(dst_root),
        "clock": clock,
    }, indent=2)
    tmp = path.with_suffix(f".tmp.{os.getpid()}")
    with open(tmp, "w") as f:
        f.write(payload)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _decode(v):
    """pywatchman BSER returns bytes for string values; normalize to str."""
    if isinstance(v, bytes):
        return v.decode("utf-8", errors="replace")
    return v


def _apply_files(src_root: Path, dst_root: Path,
                 files: list[dict], event_ts: float) -> None:
    """Mirror each (name, exists) tuple from a watchman response into
    dst_root. Missing files are deleted; present ones are copied."""
    copied = 0
    deleted = 0
    skipped = 0
    for f in files:
        name = _decode(f["name"])
        rel = Path(name)
        if _is_skipped(rel):
            skipped += 1
            continue
        if f.get("exists", True):
            try:
                src = src_root / rel
                if src.is_file():
                    _copy_inplace(src, dst_root / rel)
                    copied += 1
                # else: dir (watchman reports them too) or stale event;
                # nothing to mirror per file.
            except OSError as exc:
                # Most common cause on /mnt/c targets: Windows is holding
                # the dst file open (engine DLL race, AV scan).
                log.warning(
                    "mirror failed for %s: %s. If this is an engine DLL, "
                    "stop spring.exe / BAR launcher (just bar::stop). If "
                    "it's a Lua source, check whether the destination is "
                    "writable from WSL.", rel, exc)
        else:
            target = dst_root / rel
            try:
                target.unlink()
                deleted += 1
            except FileNotFoundError:
                pass
            except OSError as exc:
                log.warning(
                    "could not delete dst %s (Windows may hold an open "
                    "handle; next save will overwrite): %s", rel, exc)
    if copied or deleted:
        latency_ms = (time.monotonic() - event_ts) * 1000.0
        log.info("mirrored %d, deleted %d (%dms) [%s]",
                 copied, deleted, round(latency_ms), src_root.name)


def _watch_root(client: "pywatchman.client", src_root: Path) -> tuple[str, str | None]:
    """`watch-project` is idempotent and returns the watch root (which may
    be an ancestor of src_root if a parent dir is already watched). The
    `relative_path` it returns scopes our queries to our subtree."""
    resp = client.query("watch-project", str(src_root))
    return _decode(resp["watch"]), _decode(resp.get("relative_path"))


def _build_subscribe_query(relative_path: str | None,
                           since_clock: str | None) -> dict:
    q: dict = {"fields": ["name", "exists"]}
    if relative_path:
        q["relative_root"] = relative_path
    if since_clock:
        q["since"] = since_clock
    # Watchman also reports directory events; we filter to files in
    # _apply_files via src.is_file() rather than expressing a type
    # filter here, because dir-create events are useful for shaping
    # the subscription's clock advancement even though we don't copy
    # dirs themselves.
    return q


def _drain_pair(src_root: Path, dst_root: Path,
                stop: threading.Event,
                cold_only: bool,
                ready_signal: threading.Event | None) -> None:
    """One pair's subscription loop: reconnects on socket close, applies
    each batch of files, saves the latest clock after each batch."""
    state_path = _pair_state_path(src_root, dst_root)
    state = _load_pair_state(state_path)
    same_pair = (state.get("src") == str(src_root)
                 and state.get("dst") == str(dst_root))
    saved_clock = state.get("clock") if same_pair else None

    sub_name = f"bar-sync-{os.getpid()}-{src_root.name}"

    while not stop.is_set():
        try:
            client = pywatchman.client(timeout=60.0)
            try:
                watch_root, relative_path = _watch_root(client, src_root)
                query = _build_subscribe_query(relative_path, saved_clock)
                client.query("subscribe", watch_root, sub_name, query)
                if saved_clock:
                    log.info("subscription opened: %s (since clock=%s)",
                             src_root, saved_clock[-12:])
                else:
                    log.info("subscription opened: %s (no prior clock -- initial seed)",
                             src_root)

                # Receive loop. timeout=None blocks; we set a short timeout
                # to let stop-signal checks fan out without spinning hot.
                client.setTimeout(2.0)
                while not stop.is_set():
                    try:
                        msg = client.receive()
                    except pywatchman.SocketTimeout:
                        continue
                    # Subscription messages have shape:
                    # {"subscription": <name>, "files": [...], "clock": ...,
                    #  "is_fresh_instance": bool, "root": ...}
                    if not isinstance(msg, dict):
                        continue
                    if "subscription" not in msg:
                        # Could be a state-enter/state-leave message; ignore.
                        continue

                    files = msg.get("files", []) or []
                    new_clock = _decode(msg.get("clock"))
                    if msg.get("is_fresh_instance"):
                        log.info(
                            "is_fresh_instance: %s (%d files) -- "
                            "%s",
                            src_root, len(files),
                            "watchman has no prior clock for this subscription"
                            if not saved_clock else
                            "watchman daemon was restarted; saved clock invalid")

                    if files:
                        _apply_files(src_root, dst_root, files,
                                     time.monotonic())

                    if new_clock:
                        saved_clock = new_clock
                        _save_pair_state(state_path, src_root, dst_root,
                                         new_clock)

                    # First batch processed -> we're "ready"; subsequent
                    # batches keep arriving as the user edits.
                    if ready_signal is not None and not ready_signal.is_set():
                        ready_signal.set()

                    if cold_only:
                        return
            finally:
                try:
                    client.close()
                except Exception:
                    pass
        except (pywatchman.WatchmanError, OSError) as exc:
            if stop.is_set():
                return
            log.warning("watchman socket error for %s: %s -- reconnecting in 2s",
                        src_root, exc)
            stop.wait(2.0)


def _parse_pairs(pairs: Iterable[str]) -> list[tuple[Path, Path]]:
    parsed: list[tuple[Path, Path]] = []
    for raw in pairs:
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
    # would write every line twice. Foreground / interactive use (no --log)
    # gets the stderr handler so the user sees output in their terminal.
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
        description="Mirror WSL Devtools checkouts to a Windows NTFS data dir via watchman.",
    )
    parser.add_argument(
        "--pair",
        action="append",
        required=True,
        metavar="SRC::DST",
        help="Source (WSL ext4 path) and destination (POSIX form of /mnt/c/...), "
             "separated by '::'. Repeatable.",
    )
    parser.add_argument("--log", type=Path,
                        help="Append log lines to this file in addition to stderr.")
    parser.add_argument(
        "--cold-copy",
        action="store_true",
        help="Run a one-shot mirror of each pair (process the first "
             "subscription batch and exit). No watching.",
    )
    parser.add_argument(
        "--ready-file",
        type=Path,
        help="After every pair has processed its first batch, touch this file. "
        "Used by scripts/sync.sh to gate `bar-launch` invocation on a quiesced "
        "initial mirror.",
    )
    args = parser.parse_args(argv)

    _setup_logging(args.log)

    pairs = _parse_pairs(args.pair)
    log.info("sync: %d pair(s)", len(pairs))

    stop = threading.Event()

    _SIGNAL_REASONS = {
        signal.SIGINT:  "SIGINT (Ctrl-C in the foreground terminal)",
        signal.SIGTERM: "SIGTERM (likely 'just bar::stop' or 'sync.sh stop')",
        signal.SIGHUP:  "SIGHUP (controlling terminal closed)",
    }

    def _on_signal(signum, _frame):
        reason = _SIGNAL_REASONS.get(signum, f"signal {signum}")
        log.info("received %s -- closing subscriptions and exiting", reason)
        stop.set()

    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)
    try:
        signal.signal(signal.SIGHUP, _on_signal)
    except (AttributeError, ValueError):
        pass

    # One thread per pair so a slow rsync on one tree doesn't block events
    # for another. ready_events is a list of per-pair "first batch applied"
    # signals; we touch the ready file once they're all set.
    ready_events: list[threading.Event] = []
    threads: list[threading.Thread] = []
    for src, dst in pairs:
        if not src.exists():
            log.warning("skipping pair: %s does not exist", src)
            continue
        dst.mkdir(parents=True, exist_ok=True)
        ev = threading.Event()
        ready_events.append(ev)
        t = threading.Thread(
            target=_drain_pair,
            args=(src.resolve(), dst.resolve(), stop, args.cold_copy, ev),
            name=f"sync-{src.name}",
            daemon=True,
        )
        t.start()
        threads.append(t)

    if not threads:
        log.error("no pairs to mirror; exiting")
        return 1

    # Surface inotify limit at startup so a "watcher up but events never
    # arrive" pathology has an obvious first thing to check.
    try:
        with open("/proc/sys/fs/inotify/max_user_watches") as f:
            limit = int(f.read().strip())
        log.info("watcher up; %d pair(s) (fs.inotify.max_user_watches=%d)",
                 len(threads), limit)
        if limit < 131072:
            log.warning(
                "fs.inotify.max_user_watches=%d is low for BAR-sized trees; "
                "events for deep subtrees may not fire. Bump persistently:\n"
                "  echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/99-bar-devtools.conf\n"
                "  sudo sysctl -p /etc/sysctl.d/99-bar-devtools.conf", limit)
    except OSError:
        log.info("watcher up; %d pair(s) scheduled", len(threads))

    # Wait for every pair's first batch, then signal ready. Each pair's
    # _drain_pair sets its event after applying the initial seed.
    if args.ready_file is not None or args.cold_copy:
        for ev in ready_events:
            while not ev.wait(timeout=0.5):
                # If a thread died before signalling ready, its absence
                # would let us hang forever; check liveness.
                if all(not t.is_alive() for t in threads):
                    log.error("all sync threads exited before signalling ready")
                    return 1
                if stop.is_set():
                    return 0
        if args.ready_file is not None:
            args.ready_file.parent.mkdir(parents=True, exist_ok=True)
            args.ready_file.touch()

    if args.cold_copy:
        # Each pair's thread returns after its first batch. Join them.
        for t in threads:
            t.join(timeout=10)
        return 0

    # Live mode: hand control to the threads; idle here until signalled.
    while not stop.is_set():
        stop.wait(0.5)

    for t in threads:
        t.join(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
