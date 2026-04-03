# BAR Devtools

Local development environment for [Beyond All Reason](https://www.beyondallreason.info/) -- spins up **Teiserver** (lobby server), **PostgreSQL**, **SPADS** (autohost), and **bar-lobby** (game client) with a single command.

Everything server-side runs in Docker. The game client runs natively.

## Quick Start

```bash
git clone https://github.com/thvl3/BAR-Devtools.git
cd BAR-Devtools
just setup::init
just services::up
```

`setup::init` walks you through installing dependencies, cloning repositories, and building Docker images. You only need to run it once.

`services::up` starts PostgreSQL and Teiserver. On first run it seeds the database with test data and creates default accounts (~2-3 minutes). Subsequent starts are fast.

Once running:

| Service | URL |
|---------|-----|
| Teiserver Web UI | http://localhost:4000 |
| Teiserver HTTPS | https://localhost:8888 |
| Spring Protocol | `localhost:8200` (TCP) / `:8201` (TLS) |
| PostgreSQL | `localhost:5433` |

**Default login:** `root@localhost` / `password`

## Requirements

- **Linux** (Arch, Debian/Ubuntu, or Fedora)
- **Docker** with Compose V2
- **Git**
- **[just](https://github.com/casey/just)** -- command runner

```bash
# Install just
pacman -S just        # Arch
dnf install just      # Fedora
apt install just      # Debian/Ubuntu
brew install just     # Homebrew
```

Optional:

- **Node.js** (only needed if running bar-lobby)

`just setup::deps` will detect your distro and install what's missing (except `just` itself).

## Commands

Run `just` with no arguments to list everything:

```
$ just
Available recipes:
    ...
```

### Setup

| Recipe | Description |
|--------|-------------|
| `just setup::init` | Full first-time setup: install deps, clone repos, build images |
| `just setup::deps` | Install system packages (docker, git, nodejs) |
| `just setup::check` | Check prerequisites and build Docker images |

### Services

| Recipe | Description |
|--------|-------------|
| `just services::up [lobby] [spads]` | Start services (options are additive) |
| `just services::down` | Stop all services |
| `just services::status` | Show running containers |
| `just services::logs [service]` | Tail logs (postgres, teiserver, spads, or all) |
| `just services::lobby` | Start bar-lobby dev server standalone |
| `just services::shell [service]` | Shell into a container (default: teiserver) |
| `just services::build` | Build Docker images |
| `just services::reset` | Destroy all data and rebuild from scratch |

### Repositories

| Recipe | Description |
|--------|-------------|
| `just repos::clone [group]` | Clone/update repos. Groups: `core`, `extra`, `all` |
| `just repos::status` | Show status of all configured repositories |
| `just repos::update` | Pull latest on all cloned repos (fast-forward only) |

### Engine

| Recipe | Description |
|--------|-------------|
| `just engine::build <platform> [cmake-args]` | Build Recoil engine via docker-build-v2 |

### Game Directory

| Recipe | Description |
|--------|-------------|
| `just link::status` | Show symlink status |
| `just link::create <target>` | Symlink a repo into the game directory (engine, chobby, bar) |

### Lua Tooling

| Recipe | Description |
|--------|-------------|
| `just lua::build-lde` | Build lua-doc-extractor from local checkout |
| `just lua::library` | Extract Lua docs from RecoilEngine, copy into BAR submodule |
| `just lua::library-reload` | Generate library then restart LuaLS |

### Documentation

| Recipe | Description |
|--------|-------------|
| `just docs::generate` | Generate Lua API doc pages |
| `just docs::server` | Generate + start Hugo dev server |
| `just docs::server-only` | Start Hugo dev server without regenerating |

### Testing

| Recipe | Description |
|--------|-------------|
| `just test::all` | Run all BAR tests (units + integrations) |
| `just test::units` | Run busted unit tests in the BAR container |
| `just test::integrations` | Run integration tests |

## Using Your Own Forks

`repos.conf` lists the default upstream repositories. To use your own forks or work on specific branches:

```bash
cp repos.conf repos.local.conf
```

Edit `repos.local.conf` -- only include the repos you want to override:

```
teiserver  https://github.com/yourname/teiserver.git  your-branch  core
bar-lobby  https://github.com/yourname/bar-lobby.git  your-branch  core
```

Then clone or re-clone:

```bash
just repos::clone core
```

`repos.local.conf` is gitignored so it won't affect anyone else.

### Local paths

You can also point a repo entry at a local directory instead of cloning. Add a fifth column with the path:

```
lua-doc-extractor  https://github.com/rhys-vdw/lua-doc-extractor.git  main  extra  ~/code/lua-doc-extractor
```

This creates a symlink instead of cloning.

## Repository Config Format

`repos.conf` uses a simple whitespace-delimited format:

```
# directory    url    branch    group    [local_path]
teiserver      https://github.com/beyond-all-reason/teiserver.git    master    core
```

- **directory** -- local folder name (created by `clone`)
- **url** -- git clone URL
- **branch** -- branch to checkout
- **group** -- `core` (required for the dev stack) or `extra` (optional)
- **local_path** -- (optional) absolute or `~`-relative path to symlink instead of cloning

## Architecture

```
BAR-Devtools/
├── Justfile                         # Root command runner (lists all modules)
├── just/
│   ├── services.just                # Docker Compose service management
│   ├── repos.just                   # Git repository operations
│   ├── engine.just                  # RecoilEngine build
│   ├── setup.just                   # First-time setup & dependency install
│   ├── link.just                    # Game directory symlinking
│   ├── lua.just                     # lua-doc-extractor & Lua library generation
│   ├── docs.just                    # Hugo documentation server
│   └── test.just                    # Unit & integration tests
├── scripts/
│   ├── common.sh                    # Shared color/logging helpers
│   ├── repos.sh                     # repos.conf parsing & git operations
│   └── setup.sh                     # Distro detection, deps, prerequisite checks
├── repos.conf                       # Repository sources & branches
├── docker-compose.dev.yml           # Service definitions
├── docker/
│   ├── teiserver.dev.Dockerfile     # Teiserver dev image (Elixir + Phoenix)
│   ├── teiserver-entrypoint.sh      # DB init, seeding, migrations
│   ├── teiserver.dockerignore       # Build context optimization
│   ├── bar.Dockerfile               # BAR test environment (Lua 5.1 + lux)
│   ├── setup-spads-bot.exs          # Creates SPADS bot account in Teiserver
│   ├── spads-dev-entrypoint.sh      # SPADS startup + game data download
│   └── spads_dev.conf               # Simplified SPADS config for dev
├── teiserver/                       # ← cloned by just repos::clone (gitignored)
├── bar-lobby/                       # ← cloned (gitignored)
├── Beyond-All-Reason/               # ← cloned (gitignored)
├── RecoilEngine/                    # ← cloned (gitignored)
└── spads_config_bar/                # ← cloned (gitignored)
```

### What the Docker stack does

- **PostgreSQL 16** -- database for Teiserver, persisted in a Docker volume
- **Teiserver** -- runs in Elixir dev mode (`mix phx.server`). On first boot:
  - Creates the database and runs migrations
  - Seeds fake data (test users, matchmaking data)
  - Sets up Tachyon OAuth
  - Creates a `spadsbot` account with Bot/Moderator roles
- **SPADS** (optional, `services::up spads`) -- Perl autohost using `badosu/spads:latest`. Downloads game data via `pr-downloader` on first run. Connects to Teiserver via Spring protocol on port 8200.
- **bar-lobby** -- Electron/Vue.js game client, runs natively on the host (not in Docker)
- **BAR test runner** (`test` profile) -- Ubuntu container with Lua 5.1 and [lux](https://github.com/lumen-oss/lux) for running busted unit tests against the Beyond-All-Reason codebase

### Ports

| Port | Service |
|------|---------|
| 4000 | Teiserver HTTP |
| 5433 | PostgreSQL (configurable via `BAR_POSTGRES_PORT`) |
| 8200 | Spring lobby protocol (TCP) |
| 8201 | Spring lobby protocol (TLS) |
| 8888 | Teiserver HTTPS |

## SPADS

SPADS is optional and started separately because it requires downloading ~300MB of game data on first run. The download depends on external rapid repositories that can be unreliable.

```bash
just services::up spads     # Start with SPADS
just services::logs spads   # Check SPADS status
```

The SPADS bot account (`spadsbot` / `password`) is created automatically during Teiserver initialization.

## Troubleshooting

**Port 5432/5433 conflict with host PostgreSQL:**
Either stop your local PostgreSQL (`sudo systemctl stop postgresql`) or change the port:
```bash
BAR_POSTGRES_PORT=5434 just services::up
```

**Teiserver takes forever on first run:**
The initial database seeding includes generating fake data. Follow progress with:
```bash
just services::logs teiserver
```

**SPADS fails with "No Spring map/mod found":**
Game data download may have failed. Check logs and retry:
```bash
just services::logs spads
just services::down
just services::up spads
```

**Docker permission denied:**
```bash
sudo usermod -aG docker $USER
# Then log out and back in
```

**Nuclear option -- start completely fresh:**
```bash
just services::reset
just services::up
```
