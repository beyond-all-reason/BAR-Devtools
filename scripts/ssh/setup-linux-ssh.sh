#!/usr/bin/env bash
# Native-Linux 1Password SSH agent + CLI bootstrap.
#
# 1Password's Linux client exposes its agent at ~/.1password/agent.sock when
# "Use the SSH agent" is enabled in Settings → Developer. No bridge needed.
set -euo pipefail

DEVTOOLS_DIR="${DEVTOOLS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=../common.sh
source "$DEVTOOLS_DIR/scripts/common.sh"
# shellcheck source=./lib.sh
source "$DEVTOOLS_DIR/scripts/ssh/lib.sh"

detect_env

is_op_installed() {
    have 1password || have onepassword || flatpak info com.onepassword.OnePassword >/dev/null 2>&1
}

install_op_desktop() {
    case "$OP_SSH_ENV" in
        bazzite)
            info "Bazzite is rpm-ostree immutable — using Flatpak."
            if ! have flatpak; then
                err "flatpak not found on Bazzite (unexpected). Install it via rpm-ostree first."
                return 1
            fi
            flatpak install --user -y --noninteractive flathub com.onepassword.OnePassword
            ;;
        linux-arch)
            if have paru; then
                paru -S --noconfirm 1password 1password-cli
            elif have yay; then
                yay -S --noconfirm 1password 1password-cli
            else
                warn "No AUR helper (paru/yay). Install 1Password from AUR manually."
                pause "Install '1password' and '1password-cli' from the AUR"
            fi
            ;;
        linux-debian)
            info "Adding 1Password apt repository..."
            curl -sS https://downloads.1password.com/linux/keys/1password.asc \
                | sudo gpg --dearmor --yes -o /usr/share/keyrings/1password-archive-keyring.gpg
            echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main' \
                | sudo tee /etc/apt/sources.list.d/1password.list >/dev/null
            sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/
            curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol \
                | sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol >/dev/null
            sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
            curl -sS https://downloads.1password.com/linux/keys/1password.asc \
                | sudo gpg --dearmor --yes -o /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
            sudo apt-get update
            sudo apt-get install -y 1password 1password-cli
            ;;
        linux-fedora)
            info "Adding 1Password dnf repository..."
            sudo rpm --import https://downloads.1password.com/linux/keys/1password.asc
            sudo sh -c 'cat > /etc/yum.repos.d/1password.repo <<EOF
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
EOF'
            sudo dnf install -y 1password 1password-cli
            ;;
        *)
            err "Unsupported environment: $OP_SSH_ENV"
            return 1
            ;;
    esac
}

install_op_cli() {
    if have op; then
        ok "op CLI already installed ($(op --version))"
        return
    fi
    case "$OP_SSH_ENV" in
        bazzite)
            # Flatpak desktop bundle doesn't include `op`; install standalone binary.
            local arch url tmp
            arch="$(uname -m)"
            case "$arch" in
                x86_64) arch=amd64 ;;
                aarch64) arch=arm64 ;;
                *) err "unsupported arch for op CLI: $arch"; return 1 ;;
            esac
            tmp="$(mktemp -d)"
            url="https://cache.agilebits.com/dist/1P/op2/pkg/v2/op_linux_${arch}_latest.zip"
            info "Downloading op CLI from $url"
            curl -fsSL -o "$tmp/op.zip" "$url"
            (cd "$tmp" && unzip -o op.zip >/dev/null)
            mkdir -p "$HOME/.local/bin"
            install -m 0755 "$tmp/op" "$HOME/.local/bin/op"
            rm -rf "$tmp"
            ok "Installed op to ~/.local/bin/op"
            ;;
        linux-arch|linux-debian|linux-fedora)
            warn "op should have been installed alongside the desktop. Re-run install if missing."
            ;;
    esac
}

# --- Step 1: 1Password Desktop ---
step "1/5 Install 1Password Desktop"
if is_op_installed; then
    ok "1Password Desktop already installed."
else
    install_op_desktop
fi

# --- Step 2: op CLI ---
step "2/5 Install 1Password CLI"
install_op_cli

# --- Step 3: Toggle SSH agent + CLI integration ---
step "3/5 Enable SSH agent + CLI integration"
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

# --- Step 4: shell rc snippet ---
SHELL_RC="$(shellrc_path)"
step "4/5 Append SSH_AUTH_SOCK to ${SHELL_RC/#$HOME/~}"
read -r -d '' SHELLRC_BODY <<'BLOCK' || true
if [ -S "$HOME/.1password/agent.sock" ]; then
    export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"
fi
BLOCK
shellrc_apply "1password-ssh-agent" "$SHELLRC_BODY"
ok "Updated ${SHELLRC_TARGET/#$HOME/~} (block: 1password-ssh-agent)"

# --- Step 5: test ---
step "5/5 Test the agent"
SOCK="$HOME/.1password/agent.sock"
if [ ! -S "$SOCK" ]; then
    warn "$SOCK does not exist yet."
    warn "1Password may still be starting; or the SSH agent toggle isn't enabled."
    exit 0
fi
SSH_AUTH_SOCK="$SOCK" op_ssh_verify
echo ""
info "Open a new shell to pick up the ${SHELLRC_TARGET/#$HOME/~} snippet automatically."
