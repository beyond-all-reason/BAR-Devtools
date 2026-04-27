# Windows + 1Password SSH agent → WSL

Supplement to [windows-wsl2.md](./windows-wsl2.md). Covers the case where your SSH
private key lives in 1Password (not on disk), so that `git push` from inside WSL
authenticates against the 1Password agent running on Windows.

> **Status — work in progress.** Daniel maintains this from his Windows machine.
> If you hit a step that's missing or wrong, please file an issue.

## Why this is fiddly

1Password's SSH agent on Windows speaks the OpenSSH protocol over a **named pipe**
(`\\.\pipe\openssh-ssh-agent`), not a Unix socket. WSL's OpenSSH client wants a
Unix socket at `$SSH_AUTH_SOCK`. The bridge is `npiperelay.exe` + `socat`: socat
listens on a Unix socket inside WSL and shuttles bytes to/from the Windows named
pipe via npiperelay.

```
git push (WSL)
  → ssh client (WSL)
    → $SSH_AUTH_SOCK = /run/user/1000/ssh-agent.sock
      → socat (WSL)
        → npiperelay.exe (Windows, run via interop)
          → \\.\pipe\openssh-ssh-agent (1Password)
```

## Windows side

1. **Install 1Password for Windows** (the desktop app, not just the browser
   extension). Settings → Developer → enable **"Use the SSH agent"**. Optionally
   also enable **"Display key names when authorizing connections"** for visibility.

2. **Add your SSH key to 1Password** (either generate fresh in 1Password or import
   an existing key). Mark it as available to the SSH agent.

3. **Install `npiperelay.exe`.** Easiest via [scoop](https://scoop.sh):

   ```powershell
   scoop install npiperelay
   ```

   …or grab a release binary from <https://github.com/jstarks/npiperelay/releases>
   and put it somewhere on `PATH`. Verify:

   ```powershell
   where.exe npiperelay
   ```

4. **Disable Windows OpenSSH agent service** (so it doesn't compete with 1Password
   on the same named pipe):

   ```powershell
   Get-Service ssh-agent | Set-Service -StartupType Disabled
   Stop-Service ssh-agent -ErrorAction SilentlyContinue
   ```

## WSL side

1. **Install `socat`** (and optionally `psmisc` for `pkill`):

   ```bash
   sudo apt install -y socat psmisc
   ```

2. **Add the bridge to your shell rc** (`~/.bashrc` or `~/.zshrc`):

   ```bash
   # 1Password SSH agent bridge: forward $SSH_AUTH_SOCK in WSL to the
   # \\.\pipe\openssh-ssh-agent named pipe on Windows via npiperelay.
   export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"

   # Restart the bridge if no listener is on the socket.
   if ! ss -a 2>/dev/null | grep -q "$SSH_AUTH_SOCK"; then
       rm -f "$SSH_AUTH_SOCK"
       ( setsid socat UNIX-LISTEN:"$SSH_AUTH_SOCK",fork \
           EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork \
           >/dev/null 2>&1 & )
   fi
   ```

   Open a new shell. Verify:

   ```bash
   ssh-add -l                    # should list your 1Password-managed key(s)
   ssh -T git@github.com         # should authenticate
   ```

## Common gotchas

- **`npiperelay.exe: command not found` from WSL**: WSL needs to be able to invoke
  Windows binaries via interop. Confirm `/etc/wsl.conf` has `interop.enabled=true`
  (the default) and that `npiperelay.exe` is on the **Windows** `PATH`. WSL will
  see Windows `PATH` entries appended to its own `$PATH`.
- **Prompts not showing**: If 1Password is configured to confirm each use but no
  prompt appears, the desktop app may have been killed by a Windows update. Open
  it manually before pushing.
- **`ssh-add -l` says "The agent has no identities"**: 1Password agent is running
  but no key is marked as available. Check 1Password → the key item → **Use as
  SSH key** is enabled.
- **Stale socket after sleep/resume**: the rc snippet above re-spawns socat if the
  socket has no listener, but if you see "Connection refused", `pkill socat &&
  exec $SHELL` to force a refresh.

## Why not just use Windows OpenSSH and `ssh-add` your key?

That works (and is what `windows-wsl2.md` covers). 1Password buys you:

- Key never written to disk in plaintext.
- Touch-ID / Windows Hello prompt per use, instead of a passphrase typed once and
  cached for the session.
- Single source of truth across machines (laptop, desktop, etc.) without rsync'ing
  `~/.ssh`.

Skip this doc if those don't matter to you.
