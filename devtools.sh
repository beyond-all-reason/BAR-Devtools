#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
devtools.sh has been replaced by just recipes.

Install just:
  Arch:          pacman -S just
  Fedora:        dnf install just
  Debian/Ubuntu: apt install just

Then run `just` to see all available commands.

Command mapping:
  ./devtools.sh init             ->  just setup::init
  ./devtools.sh install-deps     ->  just setup::deps
  ./devtools.sh up [lobby|spads] ->  just services::up [lobby|spads]
  ./devtools.sh down             ->  just services::down
  ./devtools.sh status           ->  just services::status
  ./devtools.sh logs [service]   ->  just services::logs [service]
  ./devtools.sh lobby            ->  just services::lobby
  ./devtools.sh shell [service]  ->  just services::shell [service]
  ./devtools.sh build            ->  just services::build
  ./devtools.sh reset            ->  just services::reset
  ./devtools.sh clone [group]    ->  just repos::clone [group]
  ./devtools.sh repos            ->  just repos::status
  ./devtools.sh update           ->  just repos::update
  ./devtools.sh engine build     ->  just engine::build
  ./devtools.sh link             ->  just link::status
  ./devtools.sh link <target>    ->  just link::create <target>
EOF
exit 1
