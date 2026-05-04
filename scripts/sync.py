r"""Windows-side BAR-Devtools sync daemon (Phase 3, architecture iii).

Watches three Devtools checkout subtrees on the WSL ext4 side via UNC paths
(\\wsl$\<distro>\...) and mirrors changes to a Windows-local NTFS data dir
that the engine reads from.

Why Windows-side instead of WSL-side rsync: the Phase 1 probe found that
WSL→/mnt/c rsync at edit-loop pace (5 touches/sec) sustains a ~7s median
latency, while Windows-side watchdog reads from \\wsl$\... and writes to
NTFS at ~110ms median. The cost is one Plan9 round-trip per changed file
on the dev side; in exchange the engine reads everything from native NTFS
at gameplay rate. See bar-design-docs/bar_launch/plan.md "Probe results".

Invocation (typically via scripts/sync.sh from WSL):

    py.exe -3 scripts/sync.py \
        --pair <unc-source>:<ntfs-target> \
        --pair ... \
        --pair ... \
        [--log <path>] [--polling]

Each --pair gets its own watchdog scheduler; one process aggregates them
so the engine sees changes from all three repos cohesively.

Inode-stable writes (--inplace equivalent): we open the destination for
write+truncate and stream bytes in. We never rename a temp file over the
target, because the engine mmaps Lua sources and a rename would invalidate
the mmap mid-frame.
"""
from __future__ import annotations

import argparse
import logging
import os
import shutil
import signal
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
        "watchdog not installed in this venv. Run 'just setup::init' on WSL2 "
        "to bootstrap the Windows venv with watchdog.\n"
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


def _cold_copy(src_root: Path, dst_root: Path) -> int:
    """Walk src_root and mirror everything to dst_root. Returns file count."""
    n = 0
    for src_path in src_root.rglob("*"):
        if src_path.is_dir():
            continue
        rel = src_path.relative_to(src_root)
        if _is_skipped(rel):
            continue
        dst_path = dst_root / rel
        try:
            _copy_inplace(src_path, dst_path)
            n += 1
        except OSError as exc:
            log.warning("cold-copy failed for %s: %s", rel, exc)
    # Walk dst for entries no longer in src (rsync --delete equivalent).
    for dst_path in dst_root.rglob("*"):
        if dst_path.is_dir():
            continue
        rel = dst_path.relative_to(dst_root)
        if _is_skipped(rel):
            continue
        if not (src_root / rel).exists():
            try:
                dst_path.unlink()
            except OSError:
                pass
    return n


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
            log.warning("delete failed for %s: %s", rel, exc)

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
                log.debug("mirrored %s", rel)
            except (ValueError, OSError) as exc:
                log.warning("mirror failed for %s: %s", src_path, exc)


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
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stderr)]
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.FileHandler(str(log_path), encoding="utf-8"))
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
        help="Source (UNC \\wsl$\\... path) and destination (NTFS path), separated by '::'. Repeatable.",
    )
    parser.add_argument("--log", type=Path, help="Append log lines to this file in addition to stderr.")
    parser.add_argument(
        "--polling",
        action="store_true",
        help="Force PollingObserver instead of native ReadDirectoryChangesW. "
        "Use if Plan9 fsevents stop propagating reliably.",
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
        n = _cold_copy(src, dst)
        log.info("  %s -> %s (%d files)", src, dst, n)

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
    log.info("watcher up; %d handler(s) scheduled", len(handlers))

    if args.ready_file is not None:
        args.ready_file.parent.mkdir(parents=True, exist_ok=True)
        args.ready_file.touch()

    stop = threading.Event()

    def _on_signal(signum, _frame):
        log.info("signal %s -- shutting down", signum)
        stop.set()

    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)

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
