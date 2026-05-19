set dotenv-load

mod services 'just/services.just'
mod repos    'just/repos.just'
mod engine   'just/engine.just'
mod setup    'just/setup.just'
mod link     'just/link.just'
mod lua      'just/lua.just'
mod docs     'just/docs.just'
mod bar      'just/bar.just'
mod tei      'just/tei.just'
mod ssh      'just/ssh.just'

default:
    @just --list --list-submodules

# Diagnose your dev environment (read-only)
doctor:
    just setup::doctor

reset:
    just lua::reset
    just docs::reset
