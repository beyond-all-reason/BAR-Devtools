# Windows contributors (WSL2)

WSL2 hosts the **tooling** (clone, build, services, linker). The **game runs natively on
Windows** from the standard installer — WSLg is not used. Only build artifacts cross the
WSL↔NTFS boundary.

## Prerequisites

1. Install [Windows Terminal](https://aka.ms/terminal) from the Microsoft Store if you
   don't already have it. The legacy `wsl.exe` console window has poor copy/paste,
   no tabs, and quirky font rendering — Windows Terminal is the modern replacement
   and it tabs Linux/PowerShell/cmd in one window.

2. Install WSL2 with Ubuntu 24.04:

   ```powershell
   wsl --install -d Ubuntu-24.04
   ```

3. Enable systemd inside the distro:

   ```bash
   sudo tee /etc/wsl.conf > /dev/null <<'EOF'
   [boot]
   systemd=true
   EOF
   ```

   Then from PowerShell: `wsl --shutdown`, reopen the distro.

4. Install the Windows-native Beyond All Reason via the normal installer. The default
   install path (`%LOCALAPPDATA%\Programs\Beyond-All-Reason\data`) is auto-detected by
   `just setup::init` from inside WSL; no `BAR_GAME_DIR` needed for standard installs.

5. Inside the distro, install host dependencies and clone BAR-Devtools **under `~`** —
   never under `/mnt/c`:

   ```bash
   sudo apt install -y just podman distrobox git
   git clone https://github.com/beyond-all-reason/BAR-Devtools.git ~/BAR-Devtools
   cd ~/BAR-Devtools
   ```

   The `/mnt/c` rule matters: WSL filesystem performance and symlink semantics both
   degrade sharply on the NTFS drvfs mount.

## Run setup

```bash
just setup::init
```

Under WSL, the engine build step cross-compiles to Windows automatically via
`docker-build-v2` (mingw-w64). Output lands at `RecoilEngine/build-amd64-windows/install/`.
The link step points the Windows BAR install at that artifact.

If you want to re-link later:

```bash
just link::status               # see current symlinks
just link::create engine        # (re)link engine build to Windows install
just link::create chobby
just link::create bar
```

## Launching the game

Launch `Beyond-All-Reason.exe` natively from Windows as usual. It picks up the symlinked
dev engine and lua from the Windows install dir.

## Known risk — NTFS symlinks

Symlinks created from WSL2 into `/mnt/c/...` show up as NTFS junctions that Windows
usually follows, but this is the one part of the flow that hasn't been proven on every
Windows configuration. If `Beyond-All-Reason.exe` doesn't see your dev engine or lua
changes, the most likely cause is a symlink that Windows silently isn't following.

## VS Code

Install the [WSL extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl),
open `~/BAR-Devtools` in WSL from the Command Palette (`WSL: Open Folder in WSL...`),
and everything works as if you were on Linux.

## SSH agent forwarding

For GitHub push access from inside WSL:

```powershell
# In your Windows PowerShell profile (~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1):
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent
ssh-add ~\.ssh\id_ed25519   # or your key path
```

```bash
# In WSL ~/.bashrc or ~/.zshrc:
eval "$(ssh-agent -s)" > /dev/null 2>&1
# OR use socat to forward the Windows agent — see https://stuartleeks.com/posts/wsl-ssh-key-forward-to-windows/
```

Verify with `ssh -T git@github.com` from WSL before running `setup::init`.

If you keep your SSH key in 1Password (or Bitwarden) instead of on disk, see
[windows-1password-ssh.md](./windows-1password-ssh.md) for the agent passthrough
into WSL.
