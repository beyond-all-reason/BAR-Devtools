# BAR Devtools

Shared development environment for [Beyond All Reason](https://www.beyondallreason.info/) — game code (Lua), engine (C++), lobby server (Elixir), and autohost (Perl) all from one repo.

## Quick Start

```bash
git clone https://github.com/beyond-all-reason/BAR-Devtools.git
cd BAR-Devtools
bash scripts/bootstrap.sh         # installs `just` >= 1.31 to ~/.local/bin
exec "$SHELL" -l                  # reload PATH

just setup::init                  # full first-time setup (clones, builds, editor wiring — all prompts up front)
just services::up                 # start Postgres + Teiserver
```

Teiserver comes up at http://localhost:4000 — log in with `root@localhost` / `password`. (Full port list under [Ports](#ports).)

## Quick Setup (Windows)

The whole stack runs inside WSL2 — nothing needs native Windows. From a **PowerShell** prompt, install the VS Code WSL bridge, cap WSL2's resource use, and pull a distro:

```powershell
code --install-extension ms-vscode-remote.remote-wsl
winget install --id DEVCOM.JetBrainsMonoNerdFont   # optional — Nerd Font for the starship prompt (see Nice-to-haves)

# Leave ~5-6 GB for Windows; tune to your machine:
@"
[wsl2]
memory=12GB
swap=8GB
processors=4
"@ | Set-Content $env:USERPROFILE\.wslconfig

wsl --install -d Ubuntu-24.04
```

In **Windows Terminal**, set Ubuntu as your default profile (and, if you installed the Nerd Font above, pick *JetBrainsMono Nerd Font* under that profile's *Appearance → Font face*). Open a fresh Ubuntu terminal and follow the [Linux Quick Start](#quick-start) — it's identical:

```bash
git clone https://github.com/beyond-all-reason/BAR-Devtools.git
cd BAR-Devtools
bash scripts/bootstrap.sh
exec "$SHELL" -l

just setup::init
just services::up
```

On WSL, `setup::init` additionally prompts for a `BAR_DATA_DIR` and wires up the native-Windows launch path — the engine runs as a Windows process for performance. See [Launching from WSL2](#launching-from-wsl2) for how `just bar::launch` crosses the WSL/Windows boundary.

## Nice-to-haves

Optional — none of this is needed to build or run BAR.

<details>
<summary><strong>A more beautiful shell prompt (starship)</strong></summary>

A fresh WSL distro drops you at a barebones `user@host:~$` — no git info, exit status, or color. [starship](https://starship.rs/) fixes that. Install it into `~/.local/bin` on the host (Linux or WSL):

```bash
curl -sS https://starship.rs/install.sh | sh -s -- -b ~/.local/bin
echo 'eval "$(starship init bash)"' >> ~/.bashrc && exec bash
```

Targeting `~/.local/bin` — rather than the installer's default `/usr/local/bin`, or a distro package's `/usr/bin` — is what makes the prompt follow you into the dev container: distrobox shares your home dir and `~/.bashrc`, not host system dirs, so `distrobox enter bar-dev` picks up the same binary and init line for free.

Starship's defaults use Nerd Font glyphs. In the Windows terminal — including WSL, which renders through it — they show as boxes until you install a Nerd Font: use the `winget` line in [Quick Setup (Windows)](#quick-setup-windows), or strip the glyphs with `starship preset plain-text-symbols -o ~/.config/starship.toml`. Native Linux terminals usually have a capable font already.

</details>

<details>
<summary><strong>VS Code test switcher</strong></summary>

The [test-switcher](https://marketplace.visualstudio.com/items?itemName=bmalehorn.test-switcher) plugin jumps between BAR test and source files with `Cmd+Shift+Y` / `Ctrl+Shift+Y`. Add to your User Settings (JSON):

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

</details>

<details>
<summary><strong>Pre-commit hook (stylua + luacheck)</strong></summary>

`just setup::hooks` installs a git pre-commit hook that runs stylua and luacheck on staged Lua before each commit.

</details>

## Using Your Own Forks

`repos.conf` lists the default upstream repositories. To override any with your own fork or branch, add just the rows you want to change to `repos.local.conf` (gitignored — won't affect anyone else), then re-clone:

```bash
# repos.local.conf — only the entries you're changing:
teiserver  https://github.com/yourname/teiserver.git  your-branch
```

```bash
just repos::clone teiserver
```

The two files use **different** whitespace-delimited formats. `repos.conf`
carries the `feature` column; `repos.local.conf` does not (it only overrides
url/branch and, as an exception, a per-repo `local_path`):

```
# repos.conf        directory  url  branch  feature  [local_path]
# repos.local.conf  directory  url  branch  [local_path]
teiserver  https://github.com/yourname/teiserver.git  your-branch
```

- **directory** -- local folder name (created by `clone`)
- **url** -- git clone URL
- **branch** -- branch to checkout
- **feature** -- comma-separated tags (`bar`, `recoil`, `teiserver`, `chobby`, `spads-source`); a repo is pulled in by any of its tags (e.g. `bar-lobby` serves both `bar` and `chobby`). **`repos.conf` only** -- it's upstream classification, so `repos.local.conf` has no feature column (a stray one is ignored and flagged by `just doctor`).
- **local_path** -- (optional) absolute or `~`-relative path to **symlink** instead of clone (e.g. `~/code/lua-doc-extractor`). In `repos.local.conf` it's the 4th column -- a per-repo exception to `@local_root`.

Two optional `@`-directives can lead the file:

- `@protocol ssh` -- rewrite every `https://github.com/…` entry to its `git@github.com:…` form (or `@protocol https` for the reverse), so you don't hand-edit each URL for SSH.
- `@local_root ~/code` -- resolve any entry without a `local_path` to a symlink at `<root>/<directory>` instead of cloning -- for when you keep all the repos as siblings.

## Common Workflows

Run `just` with no arguments for the full recipe list.

### Lua development (widgets, gadgets, AI)

```bash
just bar::fmt           # format with stylua
just bar::lint          # lint with luacheck
just bar::units         # run busted unit tests
just bar::units-shell   # interactive busted shell,
                        #   run `busted -t focus` to test specs tagged "#focus"
                        #   for example: `it "should do something #focus", function()`
just bar::lx-shell      # interactive lx shell for package work
                        #   (`lx add <pkg>`, `lx sync`, `lx install`, etc.)
```

> **⚠️ Merge conflicts with master?** The project ships deterministic code transforms (formatting, API renames, Spring split) that can be replayed onto any branch. Transform your branch first, then merge:
> ```bash
> just bar::fmt-mig                       # transform your branch first
> git commit -am "apply code transforms"  # squashed away when PR merges
> git merge origin/master                 # conflicts are now real conflicts only
> ```
> This is idempotent — safe to run multiple times. Includes `bar::fmt`, so no need to run it separately.

### Teiserver development

Tests run in a separate container with `MIX_ENV=test`, so they work whether or not `services::up` is running. The test database is independent from the dev database.

```bash
just tei::setup-test-db         # initialize/migrate the test database (run once)
just tei::test                  # run the full test suite
just tei::test test/teiserver/battle_test.exs  # run a specific test file
just tei::test-shell            # interactive bash shell with MIX_ENV=test
                                #   useful for running mix commands directly
```

If you've pulled new teiserver code with migrations, re-run `just tei::setup-test-db` to apply them.

`services::up` mounts `teiserver/lib` and `teiserver/assets` into the running
container, so editing the web UI (controllers, LiveViews, templates, CSS) takes
effect live -- Phoenix recompiles and the browser at http://localhost:4000
refreshes on save, no rebuild or restart. Changes to `mix.exs`, `config/`, or
deps still need `just services::build` (or `services::up`, which rebuilds).

### Engine development

```bash
just engine::build linux        # build Recoil via docker-build-v2
just link::create engine        # symlink into game directory
```

### Launching the game (dev mode)

`just bar::launch` hands off to [bar_debug_launcher](https://github.com/beyond-all-reason/bar_debug_launcher) with your local `Beyond-All-Reason/`, `BYAR-Chobby/`, and `RecoilEngine/` checkouts wired in via `just link::create`. The Tk GUI opens by default; pass flags for headless use:

```bash
just bar::launch                                      # GUI
just bar::launch --no-gui --play chobby --source local
just bar::launch --no-gui --play bar --source local --map "Quicksilver"
just bar::launch --print-cmd --play bar --source latest
```

<details>
<summary><strong>Booting via the AppImage launcher (Linux)</strong></summary>

By default the launcher boots the engine directly. Pass `--boot launcher` to go through the AppImage launcher instead (splash + auto-update, like a real install) and point at the AppImage:

```bash
export BAR_APPIMAGE_PATH=~/Applications/Beyond-All-Reason.AppImage
just bar::launch --no-gui --play chobby --source latest --boot launcher
```

`~/Applications/` is [AppImageLauncher](https://github.com/TheAssassin/AppImageLauncher)'s canonical path; any `beyond-all-reason*.AppImage` there is auto-discovered when `BAR_APPIMAGE_PATH` points at a directory.

</details>

#### Launching from WSL2

On WSL2 the engine runs as a native Windows process (WSLg is far too slow for the game), so `just bar::launch` routes through Windows: `setup::init` does the one-time wiring (it prompts for a `BAR_DATA_DIR` -- the Windows-side data dir the engine reads from), and each launch cold-copies your checkouts onto NTFS before starting the engine there.

That copy only happens at launch and `engine::build windows` -- there's **no live edit propagation**, so re-sync to pick up Lua/source edits:

```bash
just bar::sync         # cold-copy sources without launching
just bar::sync-logs    # tail the cold-copy log
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
just services::shell teiserver  # open bash inside the running container
```
The SPADS bot account (`spadsbot` / `password`) is created automatically during Teiserver init.

## Requirements

- **Linux** (Arch, Debian/Ubuntu, Fedora) -- or **Windows** via WSL2 (see below)
- **Docker** or **Podman** with Compose V2
- **Git**
- **Bash 5+**
- **[just](https://github.com/casey/just)** -- command runner
- **[distrobox](https://distrobox.it/)** (recommended) -- dev toolchain container

`just setup::deps` will detect your distro and install what's missing (except `just` itself). `setup::init` only needs to run once; re-run `just setup::reconfigure` to change your feature/SSH/editor choices later — it re-clones for newly-selected features and prunes deselected ones (in-tree clones move to `.backups/`, never deleted).

### Dev environment (distrobox)

All dev tools (Lua 5.1, [Lux](https://github.com/lumen-oss/lux), Node.js, Cargo, clangd, StyLua) live in [`docker/dev.Containerfile`](docker/dev.Containerfile), the canonical dependency manifest. `setup::init` builds it; recipes that need these tools (`bar::lint`, `bar::fmt`, `bar::units`, …) auto-enter the distrobox. Rebuild standalone with `just setup::distrobox`.

## Architecture

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

If something isn't working, start here:

```bash
just doctor
```

This runs a read-only check of your system dependencies, environment, ports, repositories, Docker images, and running services. Every failure includes the command to fix it.

**Port 5432/5433 conflict with host PostgreSQL:**
Either stop your local PostgreSQL (`sudo systemctl stop postgresql`) or change the port:
**Port conflict with host PostgreSQL:**
```bash
BAR_POSTGRES_PORT=5434 just services::up
```

**Teiserver takes forever on first run:** Initial DB seeding generates fake data. Follow progress with `just services::logs teiserver`.

**SPADS "No Spring map/mod found":** Game data download may have failed. `just services::down && just services::up spads`.

**Docker permission denied:** `sudo usermod -aG docker $USER` then log out and back in.

**Nuclear option:** `just services::reset && just services::up`
