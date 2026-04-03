set dotenv-load

mod services 'just/services.just'
mod repos    'just/repos.just'
mod engine   'just/engine.just'
mod setup    'just/setup.just'
mod link     'just/link.just'

default:
    @just --list --list-submodules
