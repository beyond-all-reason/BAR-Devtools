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

register_module editor BAR_EDITOR_SETUP prompt_editor apply_editor
