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

default:
    @just --list --list-submodules

reset:
    just lua::reset
    just docs::reset
