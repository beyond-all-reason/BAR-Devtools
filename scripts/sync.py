"""WSL-side sync daemon: mirrors Devtools checkout subtrees through /mnt/c
into the Windows NTFS data dir via watchman. Runs inside the bar-sync
container; invoked by scripts/sync.sh. Plan 9 doesn't forward inotify, so
the watcher must run WSL-side, not Windows-side.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
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


# .git pack files are read-only on disk -> Errno 13 storms on re-copy.
_SKIP_DIRS = frozenset({".git", ".github", "__pycache__", "node_modules"})


def _is_skipped(rel: Path) -> bool:
    return any(part in _SKIP_DIRS for part in rel.parts)


def _state_dir() -> Path:
    """Persistent state dir; must stay on ext4, not /mnt/c."""
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    d = Path(base) / "bar-devtools"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _pair_state_path(src_root: Path, dst_root: Path) -> Path:
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
    # pywatchman BSER returns bytes for string values.
    if isinstance(v, bytes):
        return v.decode("utf-8", errors="replace")
    return v


def _apply_files(src_root: Path, dst_root: Path,
                 files: list[dict], event_ts: float) -> None:
    """Mirror a watchman batch into dst_root. --inplace is load-bearing:
    spring mmaps Lua sources, so a tempfile-and-rename invalidates the mmap.
    """
    changed: list[str] = []
    deleted_names: list[str] = []
    for f in files:
        name = _decode(f["name"])
        rel = Path(name)
        if _is_skipped(rel):
            continue
        if f.get("exists", True):
            changed.append(name)
        else:
            deleted_names.append(name)

    copied = 0
    if changed:
        try:
            subprocess.run(
                ["rsync", "-a", "--inplace", "--files-from=-",
                 f"{src_root}/", f"{dst_root}/"],
                input="\n".join(changed) + "\n",
                text=True,
                check=True,
            )
            copied = len(changed)
        except FileNotFoundError as exc:
            log.error("rsync not found on PATH inside container: %s", exc)
        except subprocess.CalledProcessError as exc:
            # exit 23: some files not transferred -- usually Windows holding
            # dst files open. Survivable; the next save retries.
            if exc.returncode == 23:
                log.warning(
                    "rsync exit 23 for %s -> %s (some files not transferred). "
                    "Most common cause: Windows holds open handles on the "
                    "destination. Stop spring.exe / BAR launcher (just bar::stop) "
                    "and re-trigger.", src_root, dst_root)
            else:
                log.warning("rsync exit %d for %s -> %s -- batch may be partial",
                            exc.returncode, src_root, dst_root)
            copied = 0

    deleted = 0
    for name in deleted_names:
        target = dst_root / name
        try:
            target.unlink()
            deleted += 1
        except FileNotFoundError:
            pass
        except IsADirectoryError:
            try:
                target.rmdir()
                deleted += 1
            except OSError:
                pass
        except OSError as exc:
            log.warning(
                "could not delete dst %s (Windows may hold an open "
                "handle; next save will overwrite): %s", target, exc)

    if copied or deleted:
        latency_ms = (time.monotonic() - event_ts) * 1000.0
        # Show paths for small batches; big batches collapse to a count.
        sample = changed + [f"-{n}" for n in deleted_names]
        if len(sample) <= 5:
            detail = ": " + ", ".join(sample)
        else:
            detail = ""
        log.info("mirrored %d, deleted %d (%dms) [%s]%s",
                 copied, deleted, round(latency_ms), src_root.name, detail)


def _watch_root(client: "pywatchman.client", src_root: Path) -> tuple[str, str | None]:
    resp = client.query("watch-project", str(src_root))
    return _decode(resp["watch"]), _decode(resp.get("relative_path"))


def _build_subscribe_query(relative_path: str | None,
                           since_clock: str | None) -> dict:
    q: dict = {"fields": ["name", "exists"]}
    if relative_path:
        q["relative_root"] = relative_path
    if since_clock:
        q["since"] = since_clock
    return q


def _drain_pair(src_root: Path, dst_root: Path,
                stop: threading.Event,
                cold_only: bool,
                ready_signal: threading.Event | None) -> None:
    """One pair's subscription loop; reconnects on socket close."""
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

                # Short timeout so stop-signal checks fan out without spinning.
                client.setTimeout(2.0)
                while not stop.is_set():
                    try:
                        msg = client.receive()
                    except pywatchman.SocketTimeout:
                        continue
                    if not isinstance(msg, dict):
                        continue
                    if "subscription" not in msg:
                        continue

                    files = list(msg.get("files") or [])
                    new_clock = _decode(msg.get("clock"))
                    is_fresh = bool(msg.get("is_fresh_instance"))

                    # Coalesce follow-on events from one logical save
                    # (save-then-autoformat etc.); cap at 200ms.
                    if not is_fresh and not cold_only:
                        client.setTimeout(0.05)
                        deadline = time.monotonic() + 0.20
                        while not stop.is_set() and time.monotonic() < deadline:
                            try:
                                extra = client.receive()
                            except pywatchman.SocketTimeout:
                                break
                            if not isinstance(extra, dict) \
                               or "subscription" not in extra:
                                continue
                            files.extend(extra.get("files") or [])
                            ec = _decode(extra.get("clock"))
                            if ec:
                                new_clock = ec
                            if extra.get("is_fresh_instance"):
                                is_fresh = True
                        client.setTimeout(2.0)

                    if is_fresh:
                        log.info(
                            "is_fresh_instance: %s (%d files) -- %s",
                            src_root, len(files),
                            "watchman has no prior clock for this subscription"
                            if not saved_clock else
                            "watchman daemon was restarted; saved clock invalid")

                    if files:
                        # Dedupe by name; last write wins on the exists flag.
                        latest: dict[str, dict] = {}
                        for f in files:
                            n = _decode(f.get("name"))
                            if n is None:
                                continue
                            latest[n] = f
                        _apply_files(src_root, dst_root,
                                     list(latest.values()),
                                     time.monotonic())

                    if new_clock:
                        saved_clock = new_clock
                        _save_pair_state(state_path, src_root, dst_root,
                                         new_clock)

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
    # With --log, only the FileHandler: sync.sh already redirects stderr to
    # the log, so a StreamHandler would double every line.
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

    # One thread per pair so a slow rsync on one tree doesn't block another.
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

    # Surface inotify limit at startup -- low limits silently drop events.
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

    # Wait for every pair's first batch, then signal ready.
    if args.ready_file is not None or args.cold_copy:
        for ev in ready_events:
            while not ev.wait(timeout=0.5):
                # Don't hang forever if a thread died before signalling.
                if all(not t.is_alive() for t in threads):
                    log.error("all sync threads exited before signalling ready")
                    return 1
                if stop.is_set():
                    return 0
        if args.ready_file is not None:
            args.ready_file.parent.mkdir(parents=True, exist_ok=True)
            args.ready_file.touch()

    if args.cold_copy:
        for t in threads:
            t.join(timeout=10)
        return 0

    while not stop.is_set():
        stop.wait(0.5)

    for t in threads:
        t.join(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
