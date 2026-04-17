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
just setup::init      # interactive — installs deps, clones repos, configures editor & hooks
```

Run `just` with no arguments for the full recipe list.

> **⚠️ Merge conflicts with master?** The project ships deterministic code transforms (formatting, API renames, Spring split) that can be replayed onto any branch. Transform your branch first, then merge:
> ```bash
> just bar::fmt-mig                       # transform your branch first
> git commit -am "apply code transforms"  # squashed away when PR merges
> git merge origin/master                 # conflicts are now real conflicts only
> ```
> This is idempotent — safe to run multiple times. Includes `bar::fmt`, so no need to run it separately.

## Common Commands

```bash
just bar::test            # run BAR tests (busted unit + headless integration)
just bar::check           # type-check Lua code (EmmyLua)
just bar::fmt             # format Lua code (StyLua)
just tei::test            # run Teiserver mix tests
just services::up         # start PostgreSQL + Teiserver
just services::down       # stop all services
just engine::build linux  # build Recoil engine from source
```

## Requirements

- **Linux** (Arch, Debian/Ubuntu, Fedora) or **Windows** via WSL2
- **[just](https://github.com/casey/just)** — command runner
- **Podman** or **Docker** (with Compose V2)
- **[distrobox](https://distrobox.it/)** — dev toolchain container
- **Git** — for cloning repos

Everything else (Lua 5.1, Lux, Node.js, Cargo, clangd, StyLua, EmmyLua) lives inside a distrobox built from [`docker/dev.Containerfile`](docker/dev.Containerfile). Recipes enter the distrobox automatically.

### Windows (WSL2)

Install [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install), then inside your WSL distro:

```bash
sudo apt install -y just podman distrobox git
```

**VS Code Remote — WSL:** Install the [WSL extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl), then open your WSL workspace with `code .` from the WSL terminal. This gives VS Code native access to WSL files and tools. If `code` isn't on your WSL PATH, open VS Code on Windows and run `Remote-WSL: New Window` from the Command Palette.

**SSH agent forwarding** (for GitHub push access inside WSL):

```bash
# In your Windows PowerShell profile (~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1):
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent
ssh-add ~\.ssh\id_ed25519   # or your key path

# In WSL ~/.bashrc or ~/.zshrc:
eval "$(ssh-agent -s)" > /dev/null 2>&1
# OR use socat to forward the Windows agent — see https://stuartleeks.com/posts/wsl-ssh-key-forward-to-windows/
```

Verify with `ssh -T git@github.com` from WSL before running `setup::init`.

Everything — services, testing, formatting, engine IDE integration — works unchanged inside WSL2.

## For BAR Developers (Lua)

Widgets, gadgets, AI scripts, game config.

```bash
just bar::check-errors  # type-check, errors only (no warnings/hints)
just bar::lint          # lint with luacheck
just bar::test-shell    # interactive busted shell (use `busted -t focus`)
```

### Editor integration (VS Code / Cursor)

`setup::init` configures editor integration automatically. To re-run it later:

```bash
just setup::editor      # exports language servers, installs extensions, writes settings
```

This exports `emmylua_ls`, `emmylua_check`, `clangd`, `stylua` to `~/.local/bin`, installs recommended VS Code extensions (EmmyLua, StyLua, clangd), removes conflicting ones (LuaLS/sumneko), and writes workspace `.vscode/settings.json` with format-on-save.

`setup::editor` also installs [test-switcher](https://marketplace.visualstudio.com/items?itemName=bmalehorn.test-switcher) and configures the rules in `.vscode/settings.json` — use `Ctrl+Shift+Y` / `Cmd+Shift+Y` to jump between test and source files.

## For Recoil Engine Developers (C++)

```bash
just engine::build linux        # build Recoil via docker-build-v2
just link::create engine        # symlink build into game directory
just lua::library               # regenerate Lua library stubs from engine sources
just docs::server               # generate + serve Recoil docs locally
```

`setup::editor` exports `clangd` and generates `compile_commands.json` for engine C++ support. Your editor finds the wrapper on PATH and works as if clangd is installed natively.

## For Teiserver / SPADS Developers

Start the services first — on first run, Teiserver seeds the database with test data and creates default accounts (~2-3 min):

```bash
just services::up               # start PostgreSQL + Teiserver
just services::up lobby spads   # ...with bar-lobby and SPADS
just services::down             # stop everything
just services::logs teiserver   # tail logs
```

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
