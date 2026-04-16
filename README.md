# BAR Devtools

Shared development environment for [Beyond All Reason](https://www.beyondallreason.info/) — game code (Lua), engine (C++), lobby server (Elixir), and autohost (Perl) all from one repo.

## Quick Start

```bash
# Install just (the only host dependency you need manually)
pacman -S just        # Arch
dnf install just      # Fedora
apt install just      # Debian/Ubuntu
```

```bash
git clone https://github.com/beyond-all-reason/BAR-Devtools.git
cd BAR-Devtools
just setup::init      # walks you through deps, clones repos, builds Docker images
just setup::editor    # exports language servers, configures VS Code
just setup::hooks     # installs formatting git hooks
```

`setup::init` is interactive and only needs to run once. It detects your OS, installs missing dependencies, clones repositories, and builds Docker images.

Run `just` with no arguments for the full recipe list.

> **⚠️ Merge conflicts with master?** The project ships deterministic code transforms (formatting, API renames, etc.) that can be replayed onto any branch. If your branch has conflicts after a transform PR lands, run `just bar::fmt-mig` to replay all transforms idempotently — this is the fastest way to catch up:
> ```bash
> git fetch origin
> git rebase origin/master    # resolve conflicts, then:
> just bar::fmt-mig           # re-apply formatting + transforms on top
> ```
> (This includes `bar::fmt` — no need to run it separately.)

## Requirements

- **Linux** (Arch, Debian/Ubuntu, Fedora) or **Windows** via WSL2
- **Docker** or **Podman** with Compose V2
- **Git**, **Bash 5+**
- **[just](https://github.com/casey/just)** — command runner (`just setup::deps` installs everything else)
- **[distrobox](https://distrobox.it/)** (recommended) — dev toolchain container

All dev tools (Lua 5.1, Lux, Node.js, Cargo, clangd, StyLua, EmmyLua) live inside a distrobox built from [`docker/dev.Containerfile`](docker/dev.Containerfile). Recipes that need them enter the distrobox automatically.

### Windows (WSL2)

Install [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install), then inside your WSL distro:

```bash
sudo apt install -y podman distrobox just
```

Everything — services, testing, formatting, engine IDE integration — works unchanged inside WSL2.

## For BAR Developers (Lua)

Widgets, gadgets, AI scripts, game config.

### Daily workflow

```bash
just bar::check         # type-check (EmmyLua analyzer)
just bar::check-errors  # same, but only errors — no warnings/hints
just bar::lint          # lint with luacheck
just bar::fmt           # format with stylua
just bar::units         # run busted unit tests
just bar::test-shell    # interactive busted shell (use `busted -t focus`)
```

### Editor integration (VS Code / Cursor)

```bash
just setup::editor
```

This command:
- Exports `emmylua_ls`, `emmylua_check`, `clangd`, `stylua` to `~/.local/bin`
- Installs recommended VS Code extensions (EmmyLua, StyLua, clangd)
- Removes conflicting extensions (LuaLS/sumneko — it fights EmmyLua and is dramatically slower on this codebase)
- Writes a workspace `.vscode/settings.json` with format-on-save configured

If your settings file already exists, it shows a diff against recommended defaults and leaves yours intact.

#### VS Code Test Switcher (optional)

The [test-switcher](https://marketplace.visualstudio.com/items?itemName=bmalehorn.test-switcher) plugin lets you jump between test and source files with `Cmd+Shift+Y` / `Ctrl+Shift+Y`. Add this to your User Settings (JSON):

```json
"test-switcher.rules": [
    { "pattern": "spec/(.*)_spec\\.lua", "replacement": "$1.lua" },
    { "pattern": "spec/builder_specs/(.*)_spec\\.lua", "replacement": "spec/builders/$1.lua" },
    { "pattern": "spec/builders/(.*)\\.lua", "replacement": "spec/builder_specs/$1_spec.lua" },
    { "pattern": "(luarules|common|luaui|gamedata)/(.*)\\.lua", "replacement": "spec/$1/$2_spec.lua" }
]
```

## For Recoil Engine Developers (C++)

```bash
just engine::build linux        # build Recoil via docker-build-v2
just link::create engine        # symlink build into game directory
just lua::library               # regenerate Lua library stubs from engine sources
just docs::server               # generate + serve Recoil docs locally
```

`setup::editor` exports `clangd` and generates `compile_commands.json` for engine C++ support. Your editor finds the wrapper on PATH and works as if clangd is installed natively.

## For Teiserver / SPADS Developers

```bash
just services::up               # start PostgreSQL + Teiserver
just services::up lobby spads   # ...with bar-lobby and SPADS
just services::down             # stop everything
just services::logs teiserver   # tail logs
just tei::mix                   # run Teiserver mix tests
```

On first run, Teiserver seeds the database with test data and creates default accounts (~2-3 min). Subsequent starts are fast.

| Service | URL |
|---------|-----|
| Teiserver Web UI | http://localhost:4000 |
| Teiserver HTTPS | https://localhost:8888 |
| Spring Protocol | `localhost:8200` (TCP) / `:8201` (TLS) |
| PostgreSQL | `localhost:5433` |

**Default login:** `root@localhost` / `password`

### SPADS

SPADS is optional and started separately because it downloads ~300MB of game data on first run.

```bash
just services::up spads
just services::logs spads
```

The SPADS bot account (`spadsbot` / `password`) is created automatically during Teiserver init.

## Using Your Own Forks

`repos.conf` lists default upstream repositories. To use your own forks:

```bash
cp repos.conf repos.local.conf
```

Edit `repos.local.conf` — only include repos you want to override:

```
teiserver  https://github.com/yourname/teiserver.git  your-branch  core
```

Then `just repos::clone core`. The file is gitignored.

You can also point at a local directory (fifth column) to create a symlink instead of cloning:

```
lua-doc-extractor  https://github.com/rhys-vdw/lua-doc-extractor.git  main  extra  ~/code/lua-doc-extractor
```

## Architecture

```
BAR-Devtools/
├── Justfile                         # Root command runner
├── just/
│   ├── bar.just                     # BAR Lua development (check, lint, fmt, test)
│   ├── services.just                # Docker Compose service management
│   ├── repos.just                   # Git repository operations
│   ├── engine.just                  # RecoilEngine build
│   ├── setup.just                   # First-time setup & dependency install
│   ├── link.just                    # Game directory symlinking
│   ├── lua.just                     # lua-doc-extractor & Lua library generation
│   ├── docs.just                    # Hugo documentation server
│   └── tei.just                     # Teiserver tests
├── scripts/                         # Shared shell helpers
├── claude/                          # AI agent rules for codemod work
├── repos.conf                       # Repository sources & branches
├── docker-compose.dev.yml           # Service definitions
├── docker/
│   ├── dev.Containerfile            # Distrobox dev environment
│   ├── teiserver.dev.Dockerfile     # Teiserver dev image
│   └── ...
├── Beyond-All-Reason/               # ← cloned (gitignored)
├── RecoilEngine/                    # ← cloned (gitignored)
├── teiserver/                       # ← cloned (gitignored)
└── ...
```

## Troubleshooting

**Port conflict with host PostgreSQL:**
```bash
BAR_POSTGRES_PORT=5434 just services::up
```

**Teiserver takes forever on first run:** Initial DB seeding generates fake data. Follow progress with `just services::logs teiserver`.

**SPADS "No Spring map/mod found":** Game data download may have failed. `just services::down && just services::up spads`.

**Docker permission denied:** `sudo usermod -aG docker $USER` then log out and back in.

**Nuclear option:** `just services::reset && just services::up`
