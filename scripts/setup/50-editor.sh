#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: editor.
#
# VS Code integration: install recommended extensions (EmmyLua, StyLua,
# clangd) and back out conflicting ones (sumneko.lua). Persisted as
# BAR_EDITOR_SETUP=yes|no.
#
# The legacy implementation lived as prompt_editor_setup_choice +
# run_editor_setup_choice in setup.sh; this thin module just registers
# them with the registry so they participate in the doctor table and
# `ensure_module_by_name editor`.

prompt_editor() { prompt_editor_setup_choice; }
apply_editor()  { run_editor_setup_choice; }

summary_editor() {
    if [ "$(read_env_key BAR_EDITOR_SETUP)" = "yes" ]; then
        echo "export emmylua/stylua/clangd to ~/.local/bin, write .vscode settings"
    else
        echo "no editor integration"
    fi
}

# when=deferred: editor's apply runs distrobox-export, which requires the
# bar-dev container to exist. cmd_init creates the container at step 2/N,
# AFTER the front-loaded config phase. Tagging deferred so prompt_editor
# fires at config time (front-loaded with the other prompts) but
# apply_editor runs at the end of cmd_init via apply_deferred_modules.
#
# Gated to bar,recoil: editor setup exports the Lua / C++ toolchain --
# teiserver is Elixir, so a teiserver-only contributor isn't prompted.
register_module editor BAR_EDITOR_SETUP prompt_editor apply_editor deferred bar,recoil
