#!/usr/bin/env python3
"""Minimal SpringLobby client: log a dev user into teiserver and sit in a battle.

Usage: lobby_join.py [host] [port] [user] [password] [battle_name]
Stays connected (so the user remains in the battle) until Ctrl-C.

Anything typed on stdin is sent to the battle as a SAYBATTLE line, so this
user can talk to the autohost -- e.g. type `!y` to vote yes on a pending SPADS
vote (`!n` for no, `!b` to abstain), or issue any other `!command`.
"""
import base64
import hashlib
import select
import signal
import socket
import sys
import time

host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8200
user = sys.argv[3] if len(sys.argv) > 3 else "bob"
password = sys.argv[4] if len(sys.argv) > 4 else "password"
battle_name = sys.argv[5] if len(sys.argv) > 5 else "BAR Dev autohost"

# Spring sends base64(md5(plaintext)); userID must be non-empty/non-"0" for non-bots.
pw = base64.b64encode(hashlib.md5(password.encode()).digest()).decode()
userid = str(int(hashlib.md5(user.encode()).hexdigest()[:8], 16) or 1)
# Render as a real participant: player(1<<10) + synced(1<<22) + ready(1<<1), team/ally 0.
BATTLE_STATUS = "MYBATTLESTATUS 4195330 255"

run = [True]
for sig in (signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, lambda *_: run.__setitem__(0, False))

s = socket.create_connection((host, port), timeout=15)
f = s.makefile("rwb", buffering=0)
def send(line): f.write((line + "\n").encode())

print(f"[lobby] connecting {user} -> {host}:{port}", flush=True)
f.readline()  # TASSERVER greeting
send(f"LOGIN {user} {pw} 0 * pylobby-join\t{userid}\tsp")

logged_in = False
joined = False
bid = None
last_ping = time.time()


def maybe_join():
    global joined
    if logged_in and bid and not joined:
        send(f"JOINBATTLE {bid} * sp_{user}")
        joined = True


watch = [s, sys.stdin]
while run[0]:
    if time.time() - last_ping > 20:
        send("PING")
        last_ping = time.time()
    r, _, _ = select.select(watch, [], [], 1)
    if not r:
        continue
    if sys.stdin in r:
        msg = sys.stdin.readline()
        if msg == "":            # stdin EOF (piped/backgrounded): stop watching it
            watch = [s]
        else:
            msg = msg.rstrip("\r\n")
            if msg and joined:
                send(f"SAYBATTLE {msg}")
                print(f"[lobby] {user} say: {msg}", flush=True)
            elif msg:
                print("[lobby] not in a battle yet; message dropped", flush=True)
        if s not in r:
            continue
    raw = f.readline()
    if not raw:
        print("[lobby] disconnected by server", flush=True)
        break
    line = raw.decode("utf-8", "replace").rstrip("\r\n")
    if not line:
        continue
    parts = line.split(" ")
    cmd = parts[0]
    if cmd == "DENIED":
        print(f"[lobby] login DENIED: {line}", flush=True)
        break
    elif cmd == "ACCEPTED":
        logged_in = True
        print(f"[lobby] logged in as {user}", flush=True)
    elif cmd == "BATTLEOPENED":
        tabs = line.split("\t")
        if len(tabs) > 3 and tabs[3] == battle_name:
            bid = parts[1]
            maybe_join()
    elif cmd == "BATTLECLOSED" and bid and parts[1] == bid:
        print("[lobby] battle closed; waiting for it to reopen", flush=True)
        bid, joined = None, False
    elif cmd == "LOGININFOEND":
        maybe_join()
    elif cmd == "JOINBATTLEFAILED":
        print(f"[lobby] JOIN FAILED: {line}", flush=True)
        joined = False
    elif cmd == "JOINEDBATTLE" and len(parts) >= 3 and parts[2] == user:
        send(BATTLE_STATUS)
        print(f"[lobby] {user} is in '{battle_name}' (id {bid}) -- Ctrl-C to leave", flush=True)
    elif cmd == "REQUESTBATTLESTATUS":
        send(BATTLE_STATUS)
    elif cmd == "PING":
        send("PONG")

print(f"[lobby] {user} leaving", flush=True)
try:
    send("LEAVEBATTLE")
    send("EXIT")
except OSError:
    pass
s.close()
