#!/usr/bin/env bash
# shellcheck source=scripts/setup/_lib.sh
# Module: springsettings.

prompt_springsettings() { prompt_springsettings_opt_in; }
apply_springsettings()  { :; }

summary_springsettings() {
    if [ "$(read_env_key ALLOW_SPRINGSETTINGS_MOD)" = "1" ]; then
        echo "bar::launch may modify the engine's springsettings.cfg"
    else
        echo "leave springsettings.cfg untouched"
    fi
}

register_module springsettings ALLOW_SPRINGSETTINGS_MOD prompt_springsettings apply_springsettings config bar,recoil
