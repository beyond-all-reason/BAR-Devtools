#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: ssh.
#
# Picks how to set up SSH-to-GitHub (op | manual | skip | existing) and
# runs the matching scripts/ssh/setup-*.sh script. The actual
# prompt/apply implementations live in setup.sh as
# prompt_ssh_setup_choice / run_ssh_setup_choice (long-form, with the
# "ssh -T already authenticates" autodetect) -- this file is a thin
# registration so the registry can drive both standalone via
# `ensure_module_by_name ssh`.

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
