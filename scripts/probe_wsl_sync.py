#!/usr/bin/env python3
"""WSL2 sync architecture perf probe.

Phase 1 diagnostic for `just bar::launch`. Throwaway: not wired into setup,
not invoked by any recipe. Run by hand on a Windows/WSL2 box, paste the
result table into bar_design_docs/bar_launch/plan.md under "Probe results",
then delete this file once Phase 3's architecture is chosen.

Six architectures, four scenarios each:

  (i)   WSL ext4 -> /mnt/c/... via rsync (+ watchexec for sustained)
  (ii)  Direct \\\\wsl$\\<distro>\\... reads from Windows (baseline)
  (iii) Windows-side poll + copy from \\\\wsl$\\... -> Windows-local NTFS
  (iv)  WSL-side watchdog.Observer (native inotify on ext4) + python copy
        through /mnt/c. The "what production sync.py *should* have done"
        candidate; (iii)'s watchdog ran on Windows where Plan 9 swallowed
        fsevents and degraded it to polling.
  (v)   Split-brain: WSL inotifywait writes a UNC-visible event log; a
        Windows-side python tails the log and shutil.copyfiles each touched
        file from \\\\wsl$\\... to Windows-local NTFS. Reference point for
        "what's the floor if we eat the IPC complexity?" -- compare against
        (iv) to decide whether single-process or split-brain is justified.
  (vi)  WSL-side inotifywait (-m) | cp through /mnt/c. Bash baseline that
        bounds how much overhead Python threading and watchdog add over a
        minimal C+coreutils pipeline.

  (a) cold copy / cold read of the full ~3000-file tree
  (b) incremental, 1 file changed
  (c) incremental, 50 files changed
  (d) sustained loop: 5 random files touched per second for 60s; record
      end-to-end latency from "file written WSL-side" to "new content
      readable on the target side" (median, p95, max)

Subcommands (each refuses to run on the wrong host):

  setup            (WSL)     build the synthetic source tree
  rsync            (WSL)     architecture (i): all four scenarios
  win-read         (Windows) architecture (ii): all four scenarios; (d)
                             pairs with `wsl-touch-loop` running in WSL
  win-watch        (Windows) architecture (iii): same pairing
  linux-watch      (WSL)     architecture (iv): all four scenarios,
                             self-contained (no Windows process needed)
  linux-inotifywait (WSL)    architecture (vi): same shape as (iv) using
                             inotifywait | cp instead of python+watchdog
  split-brain      (WSL)     architecture (v): inotifywait on WSL relays
                             into a UNC-visible event log; spawns a Windows-
                             side python copier via py.exe that tails the
                             log and shutil.copyfiles each event UNC->local
  split-brain-copier (Windows) windows side of (v); not invoked by hand,
                               called by `split-brain` over WSL2 interop
  wsl-touch-loop   (WSL)     standalone touch loop for win-read/win-watch
  auto             (WSL)     fully automated rerun of (ii) and/or (iii)
                             over WSL2 interop -- launches the Windows-side
                             measurer via py.exe and drives the touch loop
                             from WSL with no manual coordination
  all                        print step-by-step run instructions

Stdlib only. Output is a JSON blob plus a human-readable summary.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import random
import shutil
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path
from queue import Empty, Queue

# Tree shape mimicking BYAR-Chobby: ~3000 small Lua files, ~50 dirs.
N_FILES = 3000
N_DIRS = 50
FILE_SIZE = 200 * 1024  # 200 KB
TOUCH_PER_SEC = 5
SUSTAINED_SECS = 60
POLL_INTERVAL_S = 0.1

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

# Hard-coded for this user's box; the probe is throwaway so we don't bother
# guessing them. Override via flags if you run on a different distro/user.
# The Windows-side username is detected separately via cmd.exe interop because
# it is not always the same as the WSL username (this box: linux=daniel,
# windows=keith).
DEFAULT_DISTRO = "Ubuntu-24.04"
DEFAULT_LINUX_USER = "daniel"

_WIN_USER_CACHE: str | None = None

def _windows_user() -> str:
    global _WIN_USER_CACHE
    if _WIN_USER_CACHE is not None:
        return _WIN_USER_CACHE
    try:
        out = subprocess.run(
            ["cmd.exe", "/c", "echo %USERNAME%"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        for line in reversed(out.stdout.splitlines()):
            name = line.strip()
            if name:
                _WIN_USER_CACHE = name
                return name
    except (OSError, subprocess.SubprocessError):
        pass
    _WIN_USER_CACHE = DEFAULT_LINUX_USER
    return _WIN_USER_CACHE

def _default_src() -> Path:
    return Path(f"/home/{DEFAULT_LINUX_USER}/bar-probe-src")

def _default_rsync_dst() -> Path:
    return Path(f"/mnt/c/Users/{_windows_user()}/AppData/Local/BAR-DevSync-probe")

def _default_linux_watch_dst() -> Path:
    return Path(f"/mnt/c/Users/{_windows_user()}/AppData/Local/BAR-DevSync-probe-linwatch")

def _default_linux_inotify_dst() -> Path:
    return Path(f"/mnt/c/Users/{_windows_user()}/AppData/Local/BAR-DevSync-probe-inotify")

def _default_split_brain_dst() -> Path:
    return Path(f"/mnt/c/Users/{_windows_user()}/AppData/Local/BAR-DevSync-probe-splitbrain")

def _default_unc_src() -> str:
    return f"\\\\wsl$\\{DEFAULT_DISTRO}\\home\\{DEFAULT_LINUX_USER}\\bar-probe-src"

def _default_win_local_dst() -> str:
    # %USERPROFILE% expands inside cmd.exe; fine for hand-runs of win-watch.
    # The `auto` orchestrator passes a concrete path instead.
    return "%USERPROFILE%\\AppData\\Local\\BAR-DevSync-probe-winlocal"

def _default_probes_dir() -> Path:
    return Path(f"/home/{DEFAULT_LINUX_USER}/code/bar-design-docs/bar_launch/probes")

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

def is_wsl() -> bool:
    if platform.system() != "Linux":
        return False
    try:
        return "microsoft" in Path("/proc/version").read_text().lower()
    except OSError:
        return False

def is_windows() -> bool:
    return platform.system() == "Windows"

def require_host(kind: str) -> None:
    """Refuse to run a Windows-only mode from WSL or vice versa."""
    ok = {
        "wsl": is_wsl(),
        "windows": is_windows(),
        "linux-or-wsl": platform.system() == "Linux",
    }[kind]
    if not ok:
        sys.stderr.write(
            f"error: this subcommand must run on host kind '{kind}', "
            f"but platform is {platform.system()} (wsl={is_wsl()}).\n"
        )
        sys.exit(2)

# ---------------------------------------------------------------------------
# WSL <-> Windows path translation (used by `auto`)
# ---------------------------------------------------------------------------

def wsl_to_unc(p: Path | str) -> str:
    """Convert a WSL filesystem path to its Windows-visible form. Used to
    pass paths across the WSL2 interop boundary when launching Windows-side
    Python from WSL. `/mnt/<drive>/...` collapses to a native drive path;
    everything else is rooted under `\\\\wsl$\\<distro>\\...`."""
    pp = Path(p).resolve()
    parts = pp.parts
    if not parts or parts[0] != "/":
        raise ValueError(f"expected absolute POSIX path, got {pp}")
    if len(parts) >= 3 and parts[1] == "mnt" and len(parts[2]) == 1 and parts[2].isalpha():
        drive = parts[2].upper()
        rest = "\\".join(parts[3:])
        return f"{drive}:\\{rest}" if rest else f"{drive}:\\"
    distro = os.environ.get("WSL_DISTRO_NAME") or DEFAULT_DISTRO
    return "\\\\wsl$\\" + distro + "\\" + "\\".join(parts[1:])

def find_windows_python() -> str:
    """Locate a Windows-side Python launcher reachable from WSL via interop.
    Prefers `py.exe` (the Python launcher), falls back to `python.exe`."""
    for cand in ("py.exe", "python.exe"):
        if shutil.which(cand):
            return cand
    raise RuntimeError(
        "no Windows Python found in PATH (need py.exe or python.exe via "
        "WSL2 interop); install Python on Windows or check that interop is "
        "enabled in /etc/wsl.conf"
    )

# ---------------------------------------------------------------------------
# Marker payloads
# ---------------------------------------------------------------------------
# Every touch writes a 64-byte header `MARKER:<unix_ns>\n` followed by filler
# so total size stays at FILE_SIZE. Latency = time.time_ns() observed on the
# reader minus the ns embedded in the file. Both sides share a wall clock
# (WSL and Windows both read the host's clock; we accept their tiny skew as
# noise relative to the latencies we care about).

MARKER_PREFIX = b"MARKER:"

def make_payload(ns: int) -> bytes:
    head = MARKER_PREFIX + str(ns).encode() + b"\n"
    return head + b"x" * (FILE_SIZE - len(head))

def read_marker_ns(path: Path) -> int | None:
    try:
        with open(path, "rb") as f:
            head = f.read(64)
    except OSError:
        return None
    if not head.startswith(MARKER_PREFIX):
        return None
    try:
        return int(head[len(MARKER_PREFIX):].split(b"\n", 1)[0])
    except ValueError:
        return None

# ---------------------------------------------------------------------------
# Tree setup
# ---------------------------------------------------------------------------

def all_lua_files(root: Path) -> list[Path]:
    return sorted(root.rglob("*.lua"))

def cmd_setup(args: argparse.Namespace) -> None:
    require_host("linux-or-wsl")
    src = Path(args.src).expanduser()
    if src.exists():
        if not args.force:
            sys.stderr.write(f"{src} exists; pass --force to wipe.\n")
            sys.exit(1)
        shutil.rmtree(src)
    src.mkdir(parents=True)
    files_per_dir = N_FILES // N_DIRS
    payload = make_payload(0)
    t0 = time.monotonic()
    for d in range(N_DIRS):
        sub = src / f"unit_{d:03d}"
        sub.mkdir()
        for f in range(files_per_dir):
            (sub / f"file_{f:04d}.lua").write_bytes(payload)
    elapsed = time.monotonic() - t0
    print(
        f"created {N_FILES} files "
        f"({N_FILES * FILE_SIZE / 1e6:.1f} MB) under {src} in {elapsed:.1f}s"
    )

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def time_call(fn, *a, **kw) -> tuple[float, object]:
    t0 = time.monotonic()
    out = fn(*a, **kw)
    return time.monotonic() - t0, out

def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, **kw)

def have(prog: str) -> bool:
    return shutil.which(prog) is not None

def stats_ms(latencies_ns: list[int], trim_pct: float = 0.01) -> dict:
    """Stats over a latency series. We discard the top `trim_pct` of samples
    before computing median/p95 to keep one-off Plan9 / Defender stalls from
    swamping the central tendency, but still surface them via `max_ms_raw`
    for visibility. With a single iteration this is equivalent to dropping
    a few outliers; the real value comes from pooling across iterations in
    `cmd_auto`."""
    if not latencies_ns:
        return {"n": 0}
    ms = sorted(l / 1e6 for l in latencies_ns)
    n = len(ms)
    keep = max(1, n - int(n * trim_pct))
    trimmed = ms[:keep]
    return {
        "n": n,
        "n_after_trim": keep,
        "trim_pct": trim_pct,
        "median_ms": round(statistics.median(trimmed), 1),
        "p95_ms": round(trimmed[int(0.95 * (len(trimmed) - 1))], 1),
        "max_ms_trimmed": round(trimmed[-1], 1),
        "max_ms_raw": round(ms[-1], 1),
    }

# ---------------------------------------------------------------------------
# Touch loop
# ---------------------------------------------------------------------------

def _touch_loop(
    src: Path,
    duration_s: int,
    notify: Queue | None,
    log_path: Path | None,
    stop: threading.Event,
) -> None:
    files = all_lua_files(src)
    if len(files) < TOUCH_PER_SEC:
        raise RuntimeError(f"only {len(files)} files under {src}; run setup first")
    rng = random.Random()
    log_f = open(log_path, "w") if log_path else None
    end = time.monotonic() + duration_s
    while time.monotonic() < end and not stop.is_set():
        chosen = rng.sample(files, TOUCH_PER_SEC)
        for p in chosen:
            ns = time.time_ns()
            try:
                p.write_bytes(make_payload(ns))
            except OSError as e:
                print(f"touch failed: {p}: {e}", file=sys.stderr)
                continue
            if notify is not None:
                notify.put((ns, p))
            if log_f is not None:
                log_f.write(f"{ns}\t{p}\n")
                log_f.flush()
        time.sleep(1.0)
    if log_f is not None:
        log_f.close()

def cmd_wsl_touch_loop(args: argparse.Namespace) -> None:
    require_host("wsl")
    src = Path(args.src).expanduser()
    log = Path(args.log).expanduser() if args.log else None
    print(f"touching {TOUCH_PER_SEC}/sec in {src} for {args.duration}s "
          f"(log={log})", flush=True)
    stop = threading.Event()
    try:
        _touch_loop(src, args.duration, None, log, stop)
    except KeyboardInterrupt:
        stop.set()
    print("touch loop done")

# ---------------------------------------------------------------------------
# Latency poller (used for sustained scenario, in-process)
# ---------------------------------------------------------------------------

def _poll_for_propagation(
    src_to_dst,
    notify: Queue,
    deadline: float,
    timeout_per_event_s: float = 30.0,
) -> list[int]:
    """Drain `notify` of (touch_ns, src_path) events; for each, poll the
    mapped dst_path until its embedded marker matches touch_ns, then record
    latency_ns = time.time_ns() at that observation - touch_ns."""
    latencies: list[int] = []
    pending: list[tuple[int, Path, float]] = []  # (ns, dst, expire_at)
    while time.monotonic() < deadline or pending:
        try:
            while True:
                ns, src_path = notify.get_nowait()
                dst = src_to_dst(src_path)
                pending.append((ns, dst, time.monotonic() + timeout_per_event_s))
        except Empty:
            pass
        still: list[tuple[int, Path, float]] = []
        for ns, dst, expire in pending:
            observed = read_marker_ns(dst)
            if observed == ns:
                latencies.append(time.time_ns() - ns)
            elif time.monotonic() < expire:
                still.append((ns, dst, expire))
            # else: dropped (timeout)
        pending = still
        time.sleep(POLL_INTERVAL_S)
    return latencies

def _poll_until_drained(
    src_to_dst,
    expected: list,
    max_wait_s: float = 60.0,
    timeout_per_event_s: float = 30.0,
) -> list[int]:
    """Like _poll_for_propagation but bounded: takes a fully-known list of
    (touch_ns, src_path) and returns as soon as every entry has propagated
    (or its own timeout has expired). Used for the (b)/(c) incremental
    scenarios where we know up-front how many writes to expect."""
    pending = [(ns, src_to_dst(p), time.monotonic() + timeout_per_event_s)
               for ns, p in expected]
    latencies: list[int] = []
    end = time.monotonic() + max_wait_s
    while pending and time.monotonic() < end:
        still: list[tuple[int, Path, float]] = []
        for ns, dst, expire in pending:
            obs = read_marker_ns(dst)
            if obs == ns:
                latencies.append(time.time_ns() - ns)
            elif time.monotonic() < expire:
                still.append((ns, dst, expire))
        pending = still
        if pending:
            time.sleep(POLL_INTERVAL_S)
    return latencies

# ---------------------------------------------------------------------------
# Architecture (i): WSL rsync to /mnt/c
# ---------------------------------------------------------------------------

def _rsync(src: Path, dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    run([
        "rsync", "-a", "--delete", "--inplace",
        f"{src}/", f"{dst}/",
    ])

def cmd_rsync(args: argparse.Namespace) -> None:
    require_host("wsl")
    src = Path(args.src).expanduser()
    dst = Path(args.dst).expanduser()
    if not src.exists():
        sys.stderr.write(f"{src} missing; run `setup` first.\n")
        sys.exit(1)

    results: dict = {"architecture": "i_rsync_wsl_to_mntc", "src": str(src), "dst": str(dst)}

    # (a) cold copy
    if dst.exists():
        shutil.rmtree(dst)
    cold_s, _ = time_call(_rsync, src, dst)
    results["a_cold_copy_s"] = round(cold_s, 2)
    print(f"(a) cold copy: {cold_s:.2f}s")

    # (b) 1-file incremental
    files = all_lua_files(src)
    rng = random.Random(1)
    rng.choice(files).write_bytes(make_payload(time.time_ns()))
    inc1_s, _ = time_call(_rsync, src, dst)
    results["b_inc1_s"] = round(inc1_s, 3)
    print(f"(b) inc 1 file:  {inc1_s:.3f}s")

    # (c) 50-file incremental
    for p in rng.sample(files, 50):
        p.write_bytes(make_payload(time.time_ns()))
    inc50_s, _ = time_call(_rsync, src, dst)
    results["c_inc50_s"] = round(inc50_s, 3)
    print(f"(c) inc 50 files: {inc50_s:.3f}s")

    # (d) sustained loop
    print(f"(d) sustained {SUSTAINED_SECS}s loop...")
    notify: Queue = Queue()
    stop = threading.Event()

    def src_to_dst(p: Path) -> Path:
        return dst / p.relative_to(src)

    daemon_proc: subprocess.Popen | None = None
    poll_thread: threading.Thread | None = None
    if have("watchexec"):
        # watchexec re-runs rsync on any change under src
        daemon_proc = subprocess.Popen(
            ["watchexec", "--quiet", "-w", str(src), "--debounce", "100ms",
             "--", "rsync", "-a", "--delete", "--inplace",
             f"{str(src)}/", f"{str(dst)}/"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        results["d_propagator"] = "watchexec+rsync"
    else:
        # Fallback: poll-rsync every 200ms
        results["d_propagator"] = "poll-rsync@200ms"

        def poll_rsync():
            while not stop.is_set():
                try:
                    _rsync(src, dst)
                except subprocess.CalledProcessError:
                    pass
                time.sleep(0.2)

        poll_thread = threading.Thread(target=poll_rsync, daemon=True)
        poll_thread.start()

    touch_thread = threading.Thread(
        target=_touch_loop,
        args=(src, SUSTAINED_SECS, notify, None, stop),
        daemon=True,
    )
    touch_thread.start()
    deadline = time.monotonic() + SUSTAINED_SECS + 5
    latencies = _poll_for_propagation(src_to_dst, notify, deadline)
    stop.set()
    touch_thread.join(timeout=5)
    if daemon_proc is not None:
        daemon_proc.terminate()
        try:
            daemon_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon_proc.kill()
    if poll_thread is not None:
        poll_thread.join(timeout=5)

    results["d_sustained"] = stats_ms(latencies)
    results["d_sustained_raw_ms"] = [round(l / 1e6, 3) for l in latencies]
    print(f"(d) sustained: {results['d_sustained']}")
    _emit(args, results)

# ---------------------------------------------------------------------------
# Architectures (iv)/(vi): WSL-side native fsevents -> /mnt/c
# ---------------------------------------------------------------------------
# Both arms share the same scenario shape -- (a) cold copy via rsync (the
# watcher only handles deltas, just like a real sync daemon), then (b)/(c)/(d)
# driven by a watcher running on the Linux side. The only thing that differs
# is the watcher implementation: (iv) is python-watchdog with a worker thread,
# (vi) is `inotifywait -m` piped into a `cp` worker.
#
# Why both: the user's previous (iii) probe ran watchdog on Windows over Plan
# 9, where the OS doesn't deliver fsevents -- so it silently degraded into a
# polling loop. The proposed redesign moves detection back to the Linux side
# where inotify is native; (iv) measures the python implementation we'd
# actually ship in sync.py, and (vi) bounds how much of any tail latency is
# python+threading overhead vs. the underlying /mnt/c write path.

def _start_watchdog_observer(src: Path, dst: Path):
    """Spin up a watchdog.Observer on `src` plus a worker thread that mirrors
    every CLOSE_WRITE / CREATE event to `dst` via shutil.copyfile. Returns
    (stop_callable, errors_list). Errors during copy are swallowed into the
    list so they don't kill the worker but stay surfaceable in results."""
    try:
        from watchdog.events import FileSystemEventHandler
        from watchdog.observers import Observer
    except ImportError:
        sys.stderr.write(
            "watchdog not installed. On Ubuntu/WSL2 install via:\n"
            "  sudo apt-get install -y python3-watchdog\n"
        )
        sys.exit(1)

    q: Queue = Queue()
    errors: list[str] = []

    class H(FileSystemEventHandler):
        def on_modified(self, event):
            if not event.is_directory:
                q.put(Path(event.src_path))
        def on_created(self, event):
            if not event.is_directory:
                q.put(Path(event.src_path))

    observer = Observer()
    observer.schedule(H(), str(src), recursive=True)
    observer.start()

    stop = threading.Event()

    def worker():
        while not stop.is_set():
            try:
                p = q.get(timeout=0.1)
            except Empty:
                continue
            try:
                rel = p.relative_to(src)
            except ValueError:
                continue
            target = dst / rel
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(p, target)
            except OSError as e:
                errors.append(f"{p}: {e}")

    worker_t = threading.Thread(target=worker, daemon=True)
    worker_t.start()

    def stop_all():
        stop.set()
        worker_t.join(timeout=5)
        observer.stop()
        observer.join(timeout=5)

    return stop_all, errors


def _start_inotifywait_pipeline(src: Path, dst: Path):
    """Same shape as `_start_watchdog_observer` but uses `inotifywait -m -r`
    over a stdout reader plus a python copy worker. The copy is still
    `shutil.copyfile`; isolating only the *detection* side keeps the diff vs
    arm (iv) minimal and the comparison interpretable. (A pure-bash variant
    with `cp` instead of shutil would be even leaner but adds a fork per
    event, which we suspect is the dominant overhead -- not worth measuring
    until (iv) actually loses to (vi) by a meaningful margin.)"""
    if not have("inotifywait"):
        sys.stderr.write(
            "inotifywait not installed. On Ubuntu/WSL2 install via:\n"
            "  sudo apt-get install -y inotify-tools\n"
        )
        sys.exit(1)

    proc = subprocess.Popen(
        ["inotifywait", "-m", "-r", "-q",
         "-e", "close_write", "-e", "create",
         "--format", "%w%f",
         str(src)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
    )

    q: Queue = Queue()
    errors: list[str] = []
    stop = threading.Event()

    def reader():
        assert proc.stdout is not None
        for line in proc.stdout:
            if stop.is_set():
                return
            line = line.rstrip("\n")
            if line:
                q.put(Path(line))

    def worker():
        while not stop.is_set():
            try:
                p = q.get(timeout=0.1)
            except Empty:
                continue
            try:
                rel = p.relative_to(src)
            except ValueError:
                continue
            target = dst / rel
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(p, target)
            except OSError as e:
                errors.append(f"{p}: {e}")

    reader_t = threading.Thread(target=reader, daemon=True)
    worker_t = threading.Thread(target=worker, daemon=True)
    reader_t.start()
    worker_t.start()

    # Give inotifywait a moment to install watches before we return; otherwise
    # the first writes in (b) can race the watch setup. inotifywait -q means
    # we don't get the "Watches established." line; 250ms is generous on ext4.
    time.sleep(0.25)

    def stop_all():
        stop.set()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        reader_t.join(timeout=5)
        worker_t.join(timeout=5)

    return stop_all, errors


def _run_linux_watch_scenarios(arch_label: str, watcher_starter,
                               src: Path, dst: Path) -> dict:
    """Shared scenario runner for arms (iv)/(vi). watcher_starter is one of
    `_start_watchdog_observer` / `_start_inotifywait_pipeline`."""
    if not src.exists():
        sys.stderr.write(f"{src} missing; run `setup` first.\n")
        sys.exit(1)

    results: dict = {"architecture": arch_label, "src": str(src), "dst": str(dst)}

    # (a) cold copy via rsync. Watchers only carry deltas in production, so
    # the cold-path number is rsync's, same as arm (i). Apples-to-apples.
    if dst.exists():
        shutil.rmtree(dst)
    cold_s, _ = time_call(_rsync, src, dst)
    results["a_cold_copy_s"] = round(cold_s, 2)
    print(f"(a) cold copy (rsync): {cold_s:.2f}s")

    stop_watcher, errors = watcher_starter(src, dst)

    def src_to_dst(p: Path) -> Path:
        return dst / p.relative_to(src)

    try:
        files = all_lua_files(src)
        rng = random.Random(2)

        # (b) 1-file incremental
        chosen = rng.choice(files)
        ns_b = time.time_ns()
        chosen.write_bytes(make_payload(ns_b))
        lat_b = _poll_until_drained(src_to_dst, [(ns_b, chosen)], max_wait_s=10)
        results["b_inc1_ms"] = round(lat_b[0] / 1e6, 2) if lat_b else None
        print(f"(b) inc 1 file:  {results['b_inc1_ms']} ms")

        # (c) 50-file incremental
        expected50 = []
        for p in rng.sample(files, 50):
            ns = time.time_ns()
            p.write_bytes(make_payload(ns))
            expected50.append((ns, p))
        lat_c = _poll_until_drained(src_to_dst, expected50, max_wait_s=60)
        results["c_inc50"] = stats_ms(lat_c)
        print(f"(c) inc 50 files: {results['c_inc50']}")

        # (d) sustained 60s loop
        print(f"(d) sustained {SUSTAINED_SECS}s loop...")
        notify: Queue = Queue()
        stop_touch = threading.Event()
        touch_t = threading.Thread(
            target=_touch_loop,
            args=(src, SUSTAINED_SECS, notify, None, stop_touch),
            daemon=True,
        )
        touch_t.start()
        deadline = time.monotonic() + SUSTAINED_SECS + 5
        latencies = _poll_for_propagation(src_to_dst, notify, deadline)
        stop_touch.set()
        touch_t.join(timeout=5)
        results["d_sustained"] = stats_ms(latencies)
        results["d_sustained_raw_ms"] = [round(l / 1e6, 3) for l in latencies]
        print(f"(d) sustained: {results['d_sustained']}")
    finally:
        stop_watcher()

    if errors:
        results["copy_errors"] = errors[:20]
        results["copy_errors_total"] = len(errors)
    return results


def cmd_linux_watch(args: argparse.Namespace) -> None:
    require_host("wsl")
    src = Path(args.src).expanduser()
    dst = Path(args.dst).expanduser()
    results = _run_linux_watch_scenarios(
        "iv_linux_watchdog_to_mntc",
        _start_watchdog_observer,
        src, dst,
    )
    _emit(args, results)


def cmd_linux_inotifywait(args: argparse.Namespace) -> None:
    require_host("wsl")
    src = Path(args.src).expanduser()
    dst = Path(args.dst).expanduser()
    results = _run_linux_watch_scenarios(
        "vi_linux_inotifywait_to_mntc",
        _start_inotifywait_pipeline,
        src, dst,
    )
    _emit(args, results)


# ---------------------------------------------------------------------------
# Architecture (v): split-brain (WSL detects via inotifywait, Windows copies)
# ---------------------------------------------------------------------------
# Reference-point arm. Compared against (iv): if (v) is materially faster,
# the split-brain design is justified despite needing two processes and an
# IPC layer. If (iv) is within noise, single-process wins on simplicity.
#
# IPC mechanism: a UNC-visible event log file. WSL-side inotifywait emits
# `<wsl_abs_path>\n` per event into a python relay that fsync()s every line
# (plain inotifywait stdio is block-buffered, and Plan 9 read-side caching
# punishes that). Windows-side reader tails the file by readline polling
# and copies each event from \\wsl$\<distro>\... -> local NTFS.

def _start_inotifywait_relay(src: Path, event_log: Path):
    """Run inotifywait on `src` and relay every `<wsl_abs_path>\\n` line to
    `event_log` with explicit flush+fsync per line. Returns a stop_callable
    plus the relay thread + subprocess so the caller can clean up."""
    if not have("inotifywait"):
        sys.stderr.write(
            "inotifywait not installed. On Ubuntu/WSL2 install via:\n"
            "  sudo apt-get install -y inotify-tools\n"
        )
        sys.exit(1)

    # Truncate any stale log so the Windows tailer doesn't see prior events.
    event_log.parent.mkdir(parents=True, exist_ok=True)
    event_log.write_text("")

    proc = subprocess.Popen(
        ["inotifywait", "-m", "-r", "-q",
         "-e", "close_write", "-e", "create",
         "--format", "%w%f",
         str(src)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
    )

    log_f = open(event_log, "w", buffering=1)
    stop = threading.Event()

    def relay():
        assert proc.stdout is not None
        for line in proc.stdout:
            if stop.is_set():
                return
            log_f.write(line)
            log_f.flush()
            try:
                os.fsync(log_f.fileno())
            except OSError:
                pass

    relay_t = threading.Thread(target=relay, daemon=True)
    relay_t.start()

    # Give inotifywait a moment to install watches before the caller writes.
    time.sleep(0.3)

    def stop_all():
        stop.set()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        relay_t.join(timeout=5)
        try:
            log_f.close()
        except OSError:
            pass

    return stop_all


def cmd_split_brain(args: argparse.Namespace) -> None:
    require_host("wsl")
    src = Path(args.src).expanduser()
    dst = Path(args.dst).expanduser()
    if not src.exists():
        sys.stderr.write(f"{src} missing; run `setup` first.\n")
        sys.exit(1)

    runtime = Path(args.runtime_dir).expanduser()
    runtime.mkdir(parents=True, exist_ok=True)
    event_log = runtime / "bar-probe-split-events.log"

    pywin = find_windows_python()
    script_unc = wsl_to_unc(Path(__file__).resolve())
    src_unc = wsl_to_unc(src)
    dst_win = wsl_to_unc(dst)
    event_log_unc = wsl_to_unc(event_log)

    results: dict = {
        "architecture": "v_split_brain_wsl_detect_win_copy",
        "src": str(src), "dst": str(dst),
    }

    # (a) cold copy via rsync. Same convention as (iv)/(vi) -- the watcher
    # only carries deltas; cold uses the same primitive as arm (i).
    if dst.exists():
        shutil.rmtree(dst)
    cold_s, _ = time_call(_rsync, src, dst)
    results["a_cold_copy_s"] = round(cold_s, 2)
    print(f"(a) cold copy (rsync): {cold_s:.2f}s")

    # Spawn the Windows-side copier first so it's tailing before any events.
    # Duration buffer = SUSTAINED + (b)/(c) wall + slack.
    win_argv = [pywin, "-3", script_unc, "split-brain-copier",
                "--src", src_unc,
                "--dst", dst_win,
                "--event-log", event_log_unc,
                "--duration", str(SUSTAINED_SECS + 180)]
    print(f"spawning windows copier: {' '.join(win_argv)}", flush=True)
    win_proc = subprocess.Popen(win_argv, cwd="/mnt/c/")

    # Start inotifywait relay second so any events it produces are real
    # (post-cold-copy) deltas the windows side will have to carry.
    stop_relay = _start_inotifywait_relay(src, event_log)

    def src_to_dst(p: Path) -> Path:
        return dst / p.relative_to(src)

    try:
        files = all_lua_files(src)
        rng = random.Random(2)

        # (b) 1-file
        chosen = rng.choice(files)
        ns_b = time.time_ns()
        chosen.write_bytes(make_payload(ns_b))
        lat_b = _poll_until_drained(src_to_dst, [(ns_b, chosen)], max_wait_s=15)
        results["b_inc1_ms"] = round(lat_b[0] / 1e6, 2) if lat_b else None
        print(f"(b) inc 1 file:  {results['b_inc1_ms']} ms")

        # (c) 50-file
        expected50 = []
        for p in rng.sample(files, 50):
            ns = time.time_ns()
            p.write_bytes(make_payload(ns))
            expected50.append((ns, p))
        lat_c = _poll_until_drained(src_to_dst, expected50, max_wait_s=90)
        results["c_inc50"] = stats_ms(lat_c)
        print(f"(c) inc 50 files: {results['c_inc50']}")

        # (d) sustained 60s
        print(f"(d) sustained {SUSTAINED_SECS}s loop...")
        notify: Queue = Queue()
        stop_touch = threading.Event()
        touch_t = threading.Thread(
            target=_touch_loop,
            args=(src, SUSTAINED_SECS, notify, None, stop_touch),
            daemon=True,
        )
        touch_t.start()
        deadline = time.monotonic() + SUSTAINED_SECS + 5
        latencies = _poll_for_propagation(src_to_dst, notify, deadline)
        stop_touch.set()
        touch_t.join(timeout=5)
        results["d_sustained"] = stats_ms(latencies)
        results["d_sustained_raw_ms"] = [round(l / 1e6, 3) for l in latencies]
        print(f"(d) sustained: {results['d_sustained']}")
    finally:
        stop_relay()
        win_proc.terminate()
        try:
            win_proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            win_proc.kill()

    _emit(args, results)


def cmd_split_brain_copier(args: argparse.Namespace) -> None:
    """Windows side of arch (v). Tails an event log written by inotifywait
    on the WSL side; for each line copies the file from \\\\wsl$\\... to a
    Windows-local NTFS dst. Not intended to be invoked directly -- launched
    over WSL2 interop by `split-brain`."""
    require_host("windows")
    src = Path(args.src)        # \\wsl$\<distro>\...\bar-probe-src
    dst = Path(args.dst)        # C:\Users\...\BAR-DevSync-probe-splitbrain
    event_log = Path(args.event_log)
    dst.mkdir(parents=True, exist_ok=True)

    # Wait for the WSL side to create the event log. inotifywait + relay
    # does this within ~500ms of `split-brain` start; 30s is a safe bound.
    deadline_init = time.monotonic() + 30
    while time.monotonic() < deadline_init and not event_log.exists():
        time.sleep(0.1)
    if not event_log.exists():
        sys.stderr.write(f"event log {event_log} never appeared\n")
        sys.exit(1)

    deadline = time.monotonic() + args.duration
    copied = 0
    errors = 0
    with open(event_log, "r") as f:
        while time.monotonic() < deadline:
            line = f.readline()
            if not line:
                time.sleep(0.02)
                continue
            wsl_path = line.rstrip("\r\n")
            if not wsl_path:
                continue
            rel = _wsl_to_relative(wsl_path)
            if rel is None:
                continue
            src_file = src / rel
            target = dst / rel
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src_file, target)
                copied += 1
            except OSError:
                errors += 1
    print(f"split-brain-copier: copied={copied} errors={errors}")


# ---------------------------------------------------------------------------
# Architecture (ii): direct UNC reads (Windows-side)
# ---------------------------------------------------------------------------

def cmd_win_read(args: argparse.Namespace) -> None:
    require_host("windows")
    src = Path(args.src)  # \\wsl$\<distro>\home\<u>\bar-probe-src
    if not src.exists():
        sys.stderr.write(f"{src} not reachable (is the WSL distro running?)\n")
        sys.exit(1)
    results: dict = {"architecture": "ii_unc_direct_reads", "src": str(src)}

    # (a) cold read full tree
    def read_all() -> int:
        n = 0
        for p in src.rglob("*.lua"):
            with open(p, "rb") as f:
                f.read()
            n += 1
        return n

    cold_s, n = time_call(read_all)
    results["a_cold_read_s"] = round(cold_s, 2)
    results["a_cold_read_files"] = n
    print(f"(a) cold read:  {cold_s:.2f}s ({n} files)")

    # (b/c): nothing to "incrementally update" on the read side itself; we
    # report the time to re-read the same tree (warm read) as a sanity check.
    warm_s, _ = time_call(read_all)
    results["b_warm_reread_s"] = round(warm_s, 2)
    print(f"(b/c) warm re-read: {warm_s:.2f}s "
          f"(architecture (ii) has no propagation step to time)")

    # (d) sustained: touch loop running in WSL writes markers; we poll UNC.
    if args.non_interactive:
        if args.ready_flag:
            Path(args.ready_flag).parent.mkdir(parents=True, exist_ok=True)
            Path(args.ready_flag).touch()
        print(f"(d) sustained {SUSTAINED_SECS}s loop (driven by auto)...")
    else:
        print(f"(d) sustained {SUSTAINED_SECS}s loop "
              f"(start `wsl-touch-loop --log {args.log}` in WSL now)...")
        print("   waiting 3s for the touch loop to begin...")
        time.sleep(3)
    latencies = _poll_log_uncread(src, Path(args.log), SUSTAINED_SECS,
                                  reader=lambda p: read_marker_ns(p))
    results["d_sustained"] = stats_ms(latencies)
    results["d_sustained_raw_ms"] = [round(l / 1e6, 3) for l in latencies]
    print(f"(d) sustained: {results['d_sustained']}")
    _emit(args, results)

# ---------------------------------------------------------------------------
# Architecture (iii): Windows-side watch + copy from UNC -> local NTFS
# ---------------------------------------------------------------------------

def cmd_win_watch(args: argparse.Namespace) -> None:
    require_host("windows")
    src = Path(args.src)
    dst = Path(args.dst)
    if not src.exists():
        sys.stderr.write(f"{src} not reachable.\n")
        sys.exit(1)
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)

    results: dict = {
        "architecture": "iii_win_watch_unc_to_local",
        "src": str(src), "dst": str(dst),
    }

    def copy_all() -> int:
        n = 0
        for p in src.rglob("*.lua"):
            rel = p.relative_to(src)
            target = dst / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(p, target)
            n += 1
        return n

    cold_s, n = time_call(copy_all)
    results["a_cold_copy_s"] = round(cold_s, 2)
    results["a_cold_copy_files"] = n
    print(f"(a) cold copy: {cold_s:.2f}s ({n} files)")

    # For (b)/(c) ask the user to touch 1 / 50 in WSL, then we re-scan and
    # copy what changed. We measure scan+copy turnaround. Simpler than
    # synchronizing with a remote helper. In --non-interactive mode (auto
    # orchestrator) we skip them entirely -- only (a) and (d) feed the
    # decision matrix, and the auto path is for getting clean repeated (d)
    # samples, not for re-measuring scan+copy turnaround.
    if not args.non_interactive:
        for label, key in [("1 file", "b_inc1_s"), ("50 files", "c_inc50_s")]:
            input(f"  -- in WSL, touch {label} under the source tree, then press Enter --")
            t, _ = time_call(_scan_copy_changed, src, dst)
            results[key] = round(t, 3)
            print(f"({key[:1]}) inc {label}: {t:.3f}s")
    else:
        results["b_inc1_s"] = None
        results["c_inc50_s"] = None
        print("(b)/(c) skipped in --non-interactive mode")

    # (d) sustained: touch loop in WSL, watcher on Windows poll-copies, we
    # measure latency from marker_ns to dst-readable.
    if args.non_interactive:
        if args.ready_flag:
            Path(args.ready_flag).parent.mkdir(parents=True, exist_ok=True)
            Path(args.ready_flag).touch()
        print(f"(d) sustained {SUSTAINED_SECS}s loop (driven by auto)...")
    else:
        print(f"(d) sustained {SUSTAINED_SECS}s loop "
              f"(start `wsl-touch-loop --log {args.log}` in WSL now)...")
        print("   waiting 3s...")
        time.sleep(3)
    latencies = _poll_log_uncread(src, Path(args.log), SUSTAINED_SECS,
                                  reader=lambda p: _watcher_observe(p, src, dst))
    results["d_sustained"] = stats_ms(latencies)
    results["d_sustained_raw_ms"] = [round(l / 1e6, 3) for l in latencies]
    print(f"(d) sustained: {results['d_sustained']}")
    _emit(args, results)

def _scan_copy_changed(src: Path, dst: Path) -> int:
    """Copy any file whose mtime is newer than its dst counterpart."""
    n = 0
    for p in src.rglob("*.lua"):
        rel = p.relative_to(src)
        target = dst / rel
        try:
            src_m = p.stat().st_mtime_ns
            dst_m = target.stat().st_mtime_ns if target.exists() else 0
        except OSError:
            continue
        if src_m != dst_m:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(p, target)
            try:
                os.utime(target, ns=(src_m, src_m))
            except OSError:
                pass
            n += 1
    return n

def _watcher_observe(unc_path: Path, src_root: Path, dst_root: Path) -> int | None:
    """For arch (iii): copy unc_path -> dst_root and return marker ns of
    the freshly copied file."""
    try:
        rel = unc_path.relative_to(src_root)
    except ValueError:
        return None
    target = dst_root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.copyfile(unc_path, target)
    except OSError:
        return None
    return read_marker_ns(target)

# ---------------------------------------------------------------------------
# Log-driven poller (Windows side reads the WSL touch log, then waits for
# each touched file to become readable through its architecture)
# ---------------------------------------------------------------------------

def _poll_log_uncread(
    src_root: Path,
    log_path: Path,
    duration_s: int,
    reader,
    timeout_per_event_s: float = 30.0,
) -> list[int]:
    """Tail the WSL-side touch log (which records `<ns>\\t<wsl_abs_path>`).
    For each entry, translate the WSL path to its UNC path under src_root
    and call reader(unc_path) until it returns the matching ns; record
    latency."""
    if not log_path.exists():
        sys.stderr.write(
            f"touch log {log_path} does not exist yet; waiting up to 10s...\n"
        )
        for _ in range(100):
            if log_path.exists():
                break
            time.sleep(0.1)
    if not log_path.exists():
        sys.stderr.write("never appeared; giving up\n")
        return []

    latencies: list[int] = []
    pending: list[tuple[int, Path, float]] = []
    deadline = time.monotonic() + duration_s + 5
    f = open(log_path, "r")
    try:
        while time.monotonic() < deadline or pending:
            line = f.readline()
            if line:
                try:
                    ns_str, wsl_path = line.rstrip("\n").split("\t", 1)
                    ns = int(ns_str)
                except ValueError:
                    continue
                # Translate WSL absolute path to a child of src_root by name.
                # The touch log stored absolute WSL paths; we only need the
                # relative-to-source portion. Caller passes src_root as the
                # UNC root mirroring the WSL tree, so map by basename chain.
                rel = _wsl_to_relative(wsl_path)
                if rel is None:
                    continue
                unc_path = src_root / rel
                pending.append((ns, unc_path, time.monotonic() + timeout_per_event_s))
            still: list[tuple[int, Path, float]] = []
            for ns, p, expire in pending:
                obs = reader(p)
                if obs == ns:
                    latencies.append(time.time_ns() - ns)
                elif time.monotonic() < expire:
                    still.append((ns, p, expire))
            pending = still
            if not line:
                time.sleep(POLL_INTERVAL_S)
    finally:
        f.close()
    return latencies

def _wsl_to_relative(wsl_path: str) -> Path | None:
    # Touch log paths look like /home/<u>/bar-probe-src/unit_017/file_0042.lua
    # We want unit_017/file_0042.lua, regardless of the home prefix.
    parts = Path(wsl_path).parts
    try:
        idx = parts.index("bar-probe-src")
    except ValueError:
        return None
    rel = Path(*parts[idx + 1:])
    return rel

# ---------------------------------------------------------------------------
# Auto orchestrator: run (ii) and/or (iii) end-to-end from WSL, no manual
# coordination. Pools raw latency samples across N iterations and reports
# trimmed (top 1% dropped) median/p95 alongside the raw max.
# ---------------------------------------------------------------------------

def _run_auto_iteration(
    arch: str,
    src: Path,
    pywin: str,
    script_unc: str,
    iter_idx: int,
    out_dir: Path,
    win_dst: str,
    runtime_dir: Path,
) -> dict:
    log = runtime_dir / f"bar-probe-touch-{arch}-{iter_idx}.log"
    ready_flag = runtime_dir / f"bar-probe-ready-{arch}-{iter_idx}.flag"
    json_out = out_dir / f"probe-{arch}-auto-iter{iter_idx}.json"
    for stale in (log, ready_flag, json_out):
        if stale.exists():
            stale.unlink()

    src_unc = wsl_to_unc(src)
    log_unc = wsl_to_unc(log)
    ready_unc = wsl_to_unc(ready_flag)
    json_unc = wsl_to_unc(json_out)

    if arch == "ii":
        win_argv = [pywin, "-3", script_unc, "win-read",
                    "--src", src_unc,
                    "--log", log_unc,
                    "--non-interactive",
                    "--ready-flag", ready_unc,
                    "--json-out", json_unc]
    elif arch == "iii":
        win_argv = [pywin, "-3", script_unc, "win-watch",
                    "--src", src_unc,
                    "--dst", win_dst,
                    "--log", log_unc,
                    "--non-interactive",
                    "--ready-flag", ready_unc,
                    "--json-out", json_unc]
    else:
        raise ValueError(f"unknown arch {arch}")

    print(f"[{arch}/iter{iter_idx}] launching: {' '.join(win_argv)}", flush=True)
    # cwd=/mnt/c/ keeps the Windows process out of \\wsl$ as its working
    # directory (Windows tools refuse UNC cwds with a deprecation warning).
    win_proc = subprocess.Popen(win_argv, cwd="/mnt/c/")

    # Wait for Windows to enter the (d) phase before we start touching.
    # Cold copy can take 30-60s, so give it 5 minutes.
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline and not ready_flag.exists():
        if win_proc.poll() is not None:
            raise RuntimeError(
                f"[{arch}/iter{iter_idx}] Windows side exited before (d) "
                f"with code {win_proc.returncode}"
            )
        time.sleep(0.5)
    if not ready_flag.exists():
        win_proc.terminate()
        raise RuntimeError(f"[{arch}/iter{iter_idx}] Windows never signaled (d) ready")

    print(f"[{arch}/iter{iter_idx}] Windows ready; starting WSL touch loop "
          f"({SUSTAINED_SECS}s)", flush=True)
    touch_stop = threading.Event()
    touch_thread = threading.Thread(
        target=_touch_loop,
        args=(src, SUSTAINED_SECS, None, log, touch_stop),
        daemon=True,
    )
    touch_thread.start()
    try:
        win_proc.wait(timeout=SUSTAINED_SECS + 120)
    except subprocess.TimeoutExpired:
        win_proc.kill()
        touch_stop.set()
        raise RuntimeError(f"[{arch}/iter{iter_idx}] Windows side hung past (d)")
    touch_stop.set()
    touch_thread.join(timeout=10)

    if not json_out.exists():
        raise RuntimeError(f"[{arch}/iter{iter_idx}] no JSON at {json_out}")
    return json.loads(json_out.read_text())

def _aggregate_raw_ms(raw_per_iter: list[list[float]], trim_pct: float) -> dict:
    pooled = sorted(v for run in raw_per_iter for v in run)
    if not pooled:
        return {"n": 0}
    n = len(pooled)
    keep = max(1, n - int(n * trim_pct))
    trimmed = pooled[:keep]
    return {
        "n": n,
        "n_after_trim": keep,
        "trim_pct": trim_pct,
        "iterations": len(raw_per_iter),
        "median_ms": round(statistics.median(trimmed), 1),
        "p95_ms": round(trimmed[int(0.95 * (len(trimmed) - 1))], 1),
        "max_ms_trimmed": round(trimmed[-1], 1),
        "max_ms_raw": round(pooled[-1], 1),
    }

def cmd_auto(args: argparse.Namespace) -> None:
    require_host("wsl")
    src = Path(args.src).expanduser()
    out_dir = Path(args.out_dir).expanduser()
    runtime_dir = Path(args.runtime_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    runtime_dir.mkdir(parents=True, exist_ok=True)

    pywin = find_windows_python()
    script_unc = wsl_to_unc(Path(__file__).resolve())

    archs = ["ii", "iii"] if args.arch == "all" else [args.arch]
    print(f"auto: archs={archs} iterations={args.iterations} src={src}", flush=True)

    for arch in archs:
        per_iter_json: list[dict] = []
        for i in range(1, args.iterations + 1):
            # Reset the source tree before every iteration so file mtimes /
            # Plan9 caches start from a known state.
            cmd_setup(argparse.Namespace(src=str(src), force=True))
            result = _run_auto_iteration(
                arch=arch, src=src, pywin=pywin, script_unc=script_unc,
                iter_idx=i, out_dir=out_dir, win_dst=args.win_dst,
                runtime_dir=runtime_dir,
            )
            per_iter_json.append(result)

        raw_runs = [r.get("d_sustained_raw_ms", []) for r in per_iter_json]
        aggregate = _aggregate_raw_ms(raw_runs, trim_pct=args.trim_pct)
        cold_seconds = [r.get("a_cold_read_s") or r.get("a_cold_copy_s")
                        for r in per_iter_json]
        combined = {
            "architecture": f"{arch}_auto",
            "iterations": args.iterations,
            "trim_pct": args.trim_pct,
            "a_cold_seconds_per_iter": cold_seconds,
            "d_sustained_aggregate": aggregate,
            "per_iteration": per_iter_json,
        }
        out_path = out_dir / f"probe-{arch}-auto.json"
        out_path.write_text(json.dumps(combined, indent=2) + "\n")
        print(f"\n[{arch}] aggregate over {args.iterations} runs -> {out_path}")
        print(f"[{arch}] {aggregate}")

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def _emit(args: argparse.Namespace, results: dict) -> None:
    blob = json.dumps(results, indent=2)
    if args.json_out:
        Path(args.json_out).write_text(blob + "\n")
        print(f"wrote {args.json_out}")
    else:
        print("---")
        print(blob)

# ---------------------------------------------------------------------------
# Instructions
# ---------------------------------------------------------------------------

INSTRUCTIONS = f"""\
Phase 1 perf probe — step-by-step

Defaults are hard-coded for this box (distro={DEFAULT_DISTRO},
linux_user={DEFAULT_LINUX_USER}); pass flags to override. All commands
below assume cwd=~/code/BAR-Devtools. Each step's host is in [brackets].

============================================================
RECOMMENDED PATH — fully automated (ii) + (iii)
============================================================

1. [WSL] Architecture (i) — WSL rsync to /mnt/c. No interop, no Windows
   process; runs scenarios a/b/c/d self-contained.
     python3 scripts/probe_wsl_sync.py rsync \
         --json-out {_default_probes_dir()}/probe-i.json

1b. [WSL] Architectures (iv) and (vi) — Linux-side native fsevents to /mnt/c.
    Self-contained on WSL; no Windows process. Both follow the same shape.
    Prereqs (sudo apt-get install -y python3-watchdog inotify-tools):
      python3 scripts/probe_wsl_sync.py linux-watch \
          --json-out probes/probe-iv.json
      python3 scripts/probe_wsl_sync.py linux-inotifywait \
          --json-out probes/probe-vi.json

1c. [WSL] Architecture (v) — split-brain reference point. Spawns a Windows
    python copier over WSL2 interop; communicates via a Plan9-visible event
    log written by inotifywait. Compare against (iv) to decide whether the
    extra IPC complexity buys anything.
    Prereqs: inotify-tools on WSL, py.exe reachable from WSL via interop.
      python3 scripts/probe_wsl_sync.py split-brain \
          --json-out probes/probe-v.json

2. [WSL] Architectures (ii) and (iii), automated. Launches the Windows
   measurer over WSL2 interop (py.exe via \\\\wsl$\\... script path),
   coordinates entry into the (d) phase via a ready-flag file, drives
   the touch loop in-process, runs --iterations times per arch, pools
   the raw (d) latency samples, drops the top --trim-pct (default 1%),
   and writes per-iteration + aggregate JSON to --out-dir (default
   {_default_probes_dir()}, shared by both sides via UNC).
     python3 scripts/probe_wsl_sync.py auto --arch all --iterations 3
   Output:
     {_default_probes_dir()}/probe-ii-auto.json
     {_default_probes_dir()}/probe-iii-auto.json

3. Paste the relevant numbers into bar-design-docs/bar_launch/plan.md
   under "Probe results", then delete this script — it's throwaway.

============================================================
MANUAL FALLBACK — only if `auto` interop is broken
============================================================

Use these if py.exe isn't reachable from WSL, or if you specifically
want the win-watch (b)/(c) input-driven scan-copy turnaround numbers
that `auto` skips.

a. [WSL] Build / reset the synthetic source tree:
     python3 scripts/probe_wsl_sync.py setup --force

b. [Windows, PowerShell or cmd] Architecture (ii) — direct UNC reads.
   The --src/--log defaults already point at the WSL tree on this box;
   only --json-out needs a target:
     py -3 \\\\wsl$\\{DEFAULT_DISTRO}\\home\\{DEFAULT_LINUX_USER}\\code\\BAR-Devtools\\scripts\\probe_wsl_sync.py win-read \\
         --log \\\\wsl$\\{DEFAULT_DISTRO}\\tmp\\bar-probe-touch.log \\
         --json-out \\\\wsl$\\{DEFAULT_DISTRO}\\home\\{DEFAULT_LINUX_USER}\\code\\bar-design-docs\\bar_launch\\probes\\probe-ii.json
   (this prints "waiting 3s..."; while it waits, do step c.)

c. [WSL, separate shell] Pair with the touch loop:
     python3 scripts/probe_wsl_sync.py wsl-touch-loop \\
         --log /tmp/bar-probe-touch.log

d. Repeat steps a–c for arch (iii) with `win-watch` instead of `win-read`
   (same flags). `win-watch` will pause for manual touches in scenarios
   (b)/(c); follow its prompts.
"""

def cmd_all(_: argparse.Namespace) -> None:
    print(INSTRUCTIONS)

# ---------------------------------------------------------------------------
# Argparse
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="probe_wsl_sync",
                                description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("setup", help="(WSL) build the synthetic source tree")
    sp.add_argument("--src", default=str(_default_src()))
    sp.add_argument("--force", action="store_true")
    sp.set_defaults(func=cmd_setup)

    sp = sub.add_parser("rsync", help="(WSL) architecture (i): rsync to /mnt/c")
    sp.add_argument("--src", default=str(_default_src()))
    sp.add_argument("--dst", default=str(_default_rsync_dst()))
    sp.add_argument("--json-out", default=None)
    sp.set_defaults(func=cmd_rsync)

    sp = sub.add_parser(
        "linux-watch",
        help="(WSL) architecture (iv): python-watchdog (native inotify) -> /mnt/c",
    )
    sp.add_argument("--src", default=str(_default_src()))
    sp.add_argument("--dst", default=str(_default_linux_watch_dst()))
    sp.add_argument("--json-out", default=None)
    sp.set_defaults(func=cmd_linux_watch)

    sp = sub.add_parser(
        "linux-inotifywait",
        help="(WSL) architecture (vi): inotifywait -m | python copy worker -> /mnt/c",
    )
    sp.add_argument("--src", default=str(_default_src()))
    sp.add_argument("--dst", default=str(_default_linux_inotify_dst()))
    sp.add_argument("--json-out", default=None)
    sp.set_defaults(func=cmd_linux_inotifywait)

    sp = sub.add_parser(
        "split-brain",
        help="(WSL) architecture (v): WSL inotifywait -> UNC event log -> "
             "Windows python copier -> local NTFS",
    )
    sp.add_argument("--src", default=str(_default_src()))
    sp.add_argument("--dst", default=str(_default_split_brain_dst()),
                    help="Windows-local NTFS dst expressed as a /mnt/c/... path; "
                         "wsl_to_unc converts it for the windows side.")
    sp.add_argument("--runtime-dir", default="/tmp",
                    help="Where to put the inotify event log (must be visible "
                         "via UNC to the Windows side, so /tmp under the WSL "
                         "rootfs is the natural choice).")
    sp.add_argument("--json-out", default=None)
    sp.set_defaults(func=cmd_split_brain)

    sp = sub.add_parser(
        "split-brain-copier",
        help="(Windows) windows side of arch (v); not invoked by hand.",
    )
    sp.add_argument("--src", required=True,
                    help="UNC path to the WSL source tree (\\\\wsl$\\<distro>\\...)")
    sp.add_argument("--dst", required=True,
                    help="Windows-local NTFS dst (C:\\...)")
    sp.add_argument("--event-log", required=True,
                    help="UNC path to the WSL-side event log written by inotifywait")
    sp.add_argument("--duration", type=int, default=SUSTAINED_SECS + 180,
                    help="Seconds to keep tailing before exiting.")
    sp.set_defaults(func=cmd_split_brain_copier)

    sp = sub.add_parser("win-read", help="(Windows) architecture (ii): direct UNC reads")
    sp.add_argument("--src", default=_default_unc_src(),
                    help="UNC path to the WSL source tree")
    sp.add_argument("--log", required=True,
                    help="UNC path to the WSL-side touch log "
                         "(e.g., \\\\wsl$\\<distro>\\tmp\\bar-probe-touch.log)")
    sp.add_argument("--json-out", default=None)
    sp.add_argument("--non-interactive", action="store_true",
                    help="Skip the manual 3s sleep before (d); used by `auto`.")
    sp.add_argument("--ready-flag", default=None,
                    help="Path to touch when ready to enter (d); read by `auto`.")
    sp.set_defaults(func=cmd_win_read)

    sp = sub.add_parser("win-watch", help="(Windows) architecture (iii): poll+copy from UNC")
    sp.add_argument("--src", default=_default_unc_src())
    sp.add_argument("--dst", default=_default_win_local_dst())
    sp.add_argument("--log", required=True)
    sp.add_argument("--json-out", default=None)
    sp.add_argument("--non-interactive", action="store_true",
                    help="Skip (b)/(c) input prompts and the 3s pre-(d) sleep; "
                         "used by `auto`.")
    sp.add_argument("--ready-flag", default=None,
                    help="Path to touch when ready to enter (d); read by `auto`.")
    sp.set_defaults(func=cmd_win_watch)

    sp = sub.add_parser("wsl-touch-loop",
                        help="(WSL) standalone touch loop, paired with win-read/win-watch")
    sp.add_argument("--src", default=str(_default_src()))
    sp.add_argument("--log", default="/tmp/bar-probe-touch.log")
    sp.add_argument("--duration", type=int, default=SUSTAINED_SECS)
    sp.set_defaults(func=cmd_wsl_touch_loop)

    sp = sub.add_parser("auto",
                        help="(WSL) automated rerun of (ii) and/or (iii) with "
                             "N iterations; pools samples and trims top 1%%.")
    sp.add_argument("--arch", choices=["ii", "iii", "all"], default="all")
    sp.add_argument("--iterations", type=int, default=3,
                    help="Number of (d) sustained runs per architecture.")
    sp.add_argument("--trim-pct", type=float, default=0.01,
                    help="Fraction of pooled top samples to drop (default 0.01 = 1%%).")
    sp.add_argument("--src", default=str(_default_src()),
                    help="WSL source tree path; recreated each iteration.")
    sp.add_argument("--out-dir", default=str(_default_probes_dir()),
                    help="Where to write per-iter and aggregate JSON "
                         "(WSL path; passed to Windows side as a UNC path so "
                         "both sides write to the same folder).")
    sp.add_argument("--runtime-dir", default="/tmp",
                    help="Where to put per-iter touch logs and ready flags.")
    sp.add_argument("--win-dst", default=_default_win_local_dst(),
                    help="Windows-local NTFS dst dir for arch (iii).")
    sp.set_defaults(func=cmd_auto)

    sp = sub.add_parser("all", help="print step-by-step run instructions")
    sp.set_defaults(func=cmd_all)

    return p

def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    args.func(args)
    return 0

if __name__ == "__main__":
    sys.exit(main())
