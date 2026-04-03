# BAR Devtools

Local development environment for [Beyond All Reason](https://www.beyondallreason.info/) -- spins up **Teiserver** (lobby server), **PostgreSQL**, **SPADS** (autohost), and **bar-lobby** (game client) with a single command.

Everything server-side runs in Docker. The game client runs natively.

## Quick Start

```bash
# Install just
pacman -S just        # Arch
dnf install just      # Fedora
apt install just      # Debian/Ubuntu
```

```bash
# Run setup
git clone https://github.com/thvl3/BAR-Devtools.git
cd BAR-Devtools
just setup::init
just services::up
# recommended
just setup::editor    # export clangd + generate compile_commands.json
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

- **Linux** (Arch, Debian/Ubuntu, Fedora) -- or **Windows** via WSL2 (see below)
- **Docker** or **Podman** with Compose V2
- **Git**
- **Bash 5+**
- **[just](https://github.com/casey/just)** -- command runner
- **[distrobox](https://distrobox.it/)** (recommended) -- dev toolchain container

`just setup::deps` will detect your distro and install what's missing (except `just` itself).

### Dev environment (distrobox)

All dev tools (Lua 5.1, [Lux](https://github.com/lumen-oss/lux), Node.js, Cargo, clangd, StyLua) are defined in [`docker/dev.Containerfile`](docker/dev.Containerfile). This file is the canonical manifest of system dependencies.

Running `just setup::init` will offer to build the image and create a distrobox for you. Recipes that need these tools (`bar::lint`, `bar::fmt`, `bar::units`, `lua::library`, etc.) automatically enter the distrobox when `DEVTOOLS_DISTROBOX` is set in `.env`.

To set up a new distrobox standalone:

```bash
just setup::distrobox
```

### Editor integration (VS Code / Cursor)

Language servers and formatters live inside the distrobox. One command exports them to your host and generates `compile_commands.json` for engine C++ support:

```bash
just setup::editor
```

This exports `emmylua_ls`, `clangd`, and `stylua` as wrapper scripts in `~/.local/bin` (via `distrobox-export`), and runs `cmake` against RecoilEngine to produce `compile_commands.json` for clangd. Your editor finds the wrappers on PATH and everything works as if installed natively.

### Git hooks

Install a pre-commit hook that runs `stylua` (formatting) and `luacheck` (linting) on every commit:

```bash
just setup::hooks
```

**Recommended extensions:**

* [EmmyLua](https://marketplace.visualstudio.com/items?itemName=tangzx.emmylua) (Lua language server -- Cursor users: install from VSIX, the marketplace version is outdated)
* [StyLua](https://marketplace.visualstudio.com/items?itemName=JohnnyMorganz.stylua) (Lua formatter)
* [clangd](https://marketplace.visualstudio.com/items?itemName=llvm-vs-code-extensions.vscode-clangd) (C/C++ for engine work)

**Settings** (JSON):

```json
{
  "emmylua.ls.executablePath": "~/.local/bin/emmylua_ls",
  "[lua]": {
    "editor.defaultFormatter": "JohnnyMorganz.stylua",
    "editor.formatOnSave": true
  }
}
```

#### VS Code Test Switcher (optional)

The [test-switcher](https://marketplace.visualstudio.com/items?itemName=bmalehorn.test-switcher) plugin lets you jump between BAR test and source files with `Cmd+Shift+Y` / `Ctrl+Shift+Y`. Add this to your User Settings (JSON):

```json
"test-switcher.rules": [
    {
        "pattern": "spec/(.*)_spec\\.lua",
        "replacement": "$1.lua"
    },
    {
        "pattern": "spec/builder_specs/(.*)_spec\\.lua",
        "replacement": "spec/builders/$1.lua"
    },
    {
        "pattern": "spec/builders/(.*)\\.lua",
        "replacement": "spec/builder_specs/$1_spec.lua"
    },
    {
        "pattern": "(luarules|common|luaui|gamedata)/(.*)\\.lua",
        "replacement": "spec/$1/$2_spec.lua"
    }
]
```

### Windows (WSL2)

Install [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install), then inside your WSL distro install podman and follow the Linux instructions above:

```bash
# Inside WSL (Ubuntu)
sudo apt install -y podman distrobox
```

Everything -- services, testing, formatting, engine IDE integration -- works unchanged inside WSL2. The `dev.Containerfile` documents every dependency; if you prefer native Windows (MSYS2/mingw), use it as a reference.

## Common Workflows

Run `just` with no arguments for the full recipe list.

### Lua development (widgets, gadgets, AI)

```bash
just bar::fmt           # format with stylua
just bar::lint          # lint with luacheck
just bar::units         # run busted unit tests
just bar::test-shell    # interactive busted shell,
                        #   run `busted -t focus` to test specs tagged "#focus"
                        #   for example: `it "should do something #focus", function()`
```

### Engine development

```bash
just engine::build linux        # build Recoil via docker-build-v2
just link::create engine        # symlink into game directory
```

### Documentation

```bash
just docs::server       # generate + serve recoil docs locally
just lua::library       # regenerate lua library from engine sources
```

### Services (Teiserver, SPADS)

```bash
just services::up               # start PostgreSQL + Teiserver
just services::up lobby spads   # ...with bar-lobby and SPADS
just services::down             # stop everything
just services::logs teiserver   # tail logs
just tei::mix                   # run teiserver mix tests
```

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
lua-doc-extractor  https://github.com/rhys-vdw/lua-doc-extractor.git  your-branch  extra  ~/code/lua-doc-extractor
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
│   ├── dev.Containerfile             # Distrobox dev environment (Lua 5.1, lux, node, cargo, clangd)
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
- **Distrobox dev environment** (`just setup::distrobox`) -- Fedora container with Lua 5.1, [lux](https://github.com/lumen-oss/lux), Node.js, Cargo, clangd, and StyLua for running tests, linting, formatting, and doc generation against the BAR codebase. See [`docker/dev.Containerfile`](docker/dev.Containerfile) for the full dependency manifest.

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
