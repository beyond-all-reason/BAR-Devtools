#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: springsettings.
#
# One-time opt-in for whether bar::launch may write to the engine's
# springsettings.cfg in service of its own --debug-* flags. Persisted as
# ALLOW_SPRINGSETTINGS_MOD=0|1. No apply work -- the value is consulted
# per-launch by _apply_managed_springsettings in launch.sh.

prompt_springsettings() { prompt_springsettings_opt_in; }
apply_springsettings()  { :; }

register_module springsettings ALLOW_SPRINGSETTINGS_MOD prompt_springsettings apply_springsettings
