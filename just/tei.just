set export

DEVTOOLS_DIR    := justfile_directory()
COMPOSE_FILE    := DEVTOOLS_DIR / "docker-compose.dev.yml"
COMPOSE         := "podman compose -f " + COMPOSE_FILE
TEISERVER_DIR   := DEVTOOLS_DIR / "teiserver"

[private]
require-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_repo teiserver teiserver "Teiserver"

# Create a dev-lobby user (Chobby login: NAME / PASSWORD, default password "password").
# role defaults to a plain player (Verified) -- the point of this command is
# non-privileged accounts to exercise the player vote flow; root already covers the
# admin/direct-apply case. Pass role=mod for a Moderator (mirrors the spadsbot
# privilege pattern) when you need to test direct command execution.
add-user name password="password" role="player":
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    # one-off container (not exec) so the app's listeners don't clash with the running teiserver
    {{COMPOSE}} run --rm --entrypoint "" -e DEVU="{{name}}" -e DEVP="{{password}}" -e DEVROLE="{{role}}" teiserver mix run -e '
      n = System.get_env("DEVU"); alias Teiserver.Account
      {roles, perms} = case System.get_env("DEVROLE") do
        r when r in ["mod", "moderator", "Moderator"] -> {["Verified", "Moderator"], ["Server"]}
        _ -> {["Verified"], ["Verified"]}
      end
      case Account.get_user_by_name(n) do
        nil -> {:ok, u} = Account.create_user(%{name: n, email: n<>"@dev.local", password: Account.spring_md5_password(System.get_env("DEVP")), roles: roles, permissions: perms, data: %{}}); IO.puts("created #{u.name} #{inspect(roles)}")
        u -> IO.puts("already exists: #{u.name}")
      end'
    ok "Dev lobby user ready -- Chobby login: {{name}} / {{password}}"

# Log a dev user into the local lobby and keep them sitting in a battle (Ctrl-C to leave)
join-battle name="bob" password="password" battle="BAR Dev autohost":
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    info "Joining '{{battle}}' as {{name}} -- Ctrl-C to leave"
    exec python3 "$DEVTOOLS_DIR/scripts/lobby_join.py" 127.0.0.1 8200 "{{name}}" "{{password}}" "{{battle}}"

# Initialize and migrate the test database
setup-test-db: require-setup
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} run --rm -e MIX_ENV=test --entrypoint "" \
        teiserver bash -c "mix ecto.create --quiet 2>/dev/null; mix ecto.migrate --quiet"

# Run teiserver mix tests (arguments optional)
test *args: require-setup
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} run --rm -e MIX_ENV=test --entrypoint "" \
        -v {{TEISERVER_DIR}}/test:/app/test:z \
        teiserver mix test {{args}}


# Run teiserver mix in dev mode (expects a mix task to be provided, arguments optional)
mix *args: require-setup
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} run --rm --service-ports -e MIX_ENV=dev --entrypoint "" \
        teiserver mix {{args}}


# Drop into an interactive dev shell for teiserver
dev-shell: require-setup
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} run --rm --service-ports -e MIX_ENV=dev --entrypoint "" \
        teiserver bash -c "echo 'Entering teiserver dev shell (MIX_ENV=dev). Type exit to return.' && exec bash"

# Drop into an interactive test shell for teiserver
test-shell: require-setup
    #!/usr/bin/env bash
    set -euo pipefail
    source "$DEVTOOLS_DIR/scripts/common.sh"
    require_host
    {{COMPOSE}} run --rm -e MIX_ENV=test --entrypoint "" \
        -v {{TEISERVER_DIR}}/test:/app/test:z \
        teiserver bash -c "echo 'Entering teiserver test shell (MIX_ENV=test). Type exit to return.' && exec bash"
