#!/usr/bin/env bash
# WSL <-> Windows 1Password SSH agent bridge.
# Chain: $SSH_AUTH_SOCK -> socat (WSL) -> npiperelay.exe -> 1Password's named pipe.
set -euo pipefail

DEVTOOLS_DIR="${DEVTOOLS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=../common.sh
source "$DEVTOOLS_DIR/scripts/common.sh"
# shellcheck source=./lib.sh
source "$DEVTOOLS_DIR/scripts/ssh/lib.sh"

is_wsl || { err "setup-wsl-ssh.sh must run inside WSL."; exit 1; }

NPIPERELAY_URL="https://github.com/jstarks/npiperelay/releases/latest/download/npiperelay_windows_amd64.zip"

winget_install() {
    local id="$1" name="$2"
    if ! have powershell.exe; then
        warn "powershell.exe not on PATH — cannot drive winget. Install $name manually."
        return 1
    fi
    info "Checking winget for $name ($id)..."
    if powershell.exe -NoProfile -Command "winget list --id $id -e" >/dev/null 2>&1; then
        ok "$name already installed (winget reports it present)."
        return 0
    fi
    info "Installing $name via winget..."
    powershell.exe -NoProfile -Command \
        "winget install --id $id -e --accept-source-agreements --accept-package-agreements --silent" \
        || { warn "winget install of $name failed."; return 1; }
    ok "$name installed."
}

step "1/7 Install 1Password Desktop on Windows"
if ! winget_install "AgileBits.1Password" "1Password Desktop"; then
    pause "Download and install 1Password from https://1password.com/downloads/windows/"
fi

step "2/7 Install 1Password CLI on Windows"
if ! winget_install "AgileBits.1Password.CLI" "1Password CLI"; then
    pause "Download and install the 1Password CLI from https://developer.1password.com/docs/cli/get-started/"
fi

step "3/7 Enable SSH agent + CLI integration"
if op_ssh_already_active; then
    ok "1Password SSH agent already serving keys -- skipping toggle prompt."
else
    cat <<EOF
       In 1Password Desktop:
         Settings → Developer
           [x] Use the SSH agent
           [x] Integrate with 1Password CLI
         Settings → Security
           Lock after the system is idle for: 4 hours
       (BAR's first-time download/build is long enough that the default
        15 minutes will re-lock the vault mid-setup and break SSH ops.)
       Then sign in to your account if you haven't already.
EOF
    pause "Toggle both Developer checkboxes and bump idle-lock to 4 hours"
fi

step "4/7 Install socat in WSL"
if have socat; then
    ok "socat already installed."
else
    info "Running: sudo apt-get update && sudo apt-get install -y socat"
    sudo apt-get update
    sudo apt-get install -y socat
fi

step "5/7 Install npiperelay.exe on the Windows side"
WIN_HOME="$(win_userprofile)"
NPR_DIR="${WIN_HOME}/AppData/Local/npiperelay"
NPR_EXE="${NPR_DIR}/npiperelay.exe"
mkdir -p "$NPR_DIR"
if [ -x "$NPR_EXE" ]; then
    ok "npiperelay.exe already at $NPR_EXE"
else
    info "Downloading npiperelay..."
    tmp="$(mktemp -d)"
    curl -fL --progress-bar -o "$tmp/npr.zip" "$NPIPERELAY_URL"
    if ! have unzip; then
        info "unzip missing; installing..."
        sudo apt-get install -y unzip
    fi
    unzip -o "$tmp/npr.zip" -d "$NPR_DIR" >/dev/null
    rm -rf "$tmp"
    [ -x "$NPR_EXE" ] || { err "extraction did not produce $NPR_EXE"; exit 1; }
    ok "Installed $NPR_EXE"
fi
mkdir -p "$HOME/.local/bin"
ln -sf "$NPR_EXE" "$HOME/.local/bin/npiperelay.exe"

SHELL_RC="$(shellrc_path)"
step "6/7 Append bridge snippet to ${SHELL_RC/#$HOME/~}"
read -r -d '' SHELLRC_BODY <<'BLOCK' || true
export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
if ! ss -xl 2>/dev/null | grep -q "$SSH_AUTH_SOCK"; then
    rm -f "$SSH_AUTH_SOCK"
    (setsid socat UNIX-LISTEN:"$SSH_AUTH_SOCK",fork \
        EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork \
        >/dev/null 2>&1 &)
fi
BLOCK
shellrc_apply "1password-ssh-agent" "$SHELLRC_BODY"
ok "Updated ${SHELLRC_TARGET/#$HOME/~} (block: 1password-ssh-agent)"

step "7/7 Test the bridge"
export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
rm -f "$SSH_AUTH_SOCK"
PATH="$HOME/.local/bin:$PATH" setsid socat UNIX-LISTEN:"$SSH_AUTH_SOCK",fork \
    EXEC:"npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork \
    >/dev/null 2>&1 &
sleep 1
op_ssh_verify
echo ""
info "Open a new shell to pick up the bashrc snippet automatically."
