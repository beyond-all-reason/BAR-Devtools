#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: ssh.

prompt_ssh() { prompt_ssh_setup_choice; }
apply_ssh()  { run_ssh_setup_choice; }

summary_ssh() {
    local v; v="$(read_env_key BAR_SSH_SETUP)"
    case "$v" in
        op)       echo "configure GitHub SSH via 1Password" ;;
        manual)   echo "generate a GitHub SSH key, paste it to GitHub" ;;
        existing) echo "use the SSH key already on this machine" ;;
        skip)     echo "skip GitHub SSH setup" ;;
        *)        echo "${v:-<unset>}" ;;
    esac
}

register_module ssh BAR_SSH_SETUP prompt_ssh apply_ssh
