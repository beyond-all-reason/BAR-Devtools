#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: editor.

prompt_editor() { prompt_editor_setup_choice; }
apply_editor()  { run_editor_setup_choice; }

summary_editor() {
    if [ "$(read_env_key BAR_EDITOR_SETUP)" = "yes" ]; then
        echo "export emmylua/stylua/clangd to ~/.local/bin, write .vscode settings"
    else
        echo "no editor integration"
    fi
}

# deferred: apply_editor runs distrobox-export, which needs the bar-dev
# container that cmd_init only creates after the config phase.
register_module editor BAR_EDITOR_SETUP prompt_editor apply_editor deferred bar,recoil
