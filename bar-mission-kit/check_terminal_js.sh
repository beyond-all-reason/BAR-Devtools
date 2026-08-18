#!/usr/bin/env bash
# The browser terminal's script is embedded in terminal.html, so a syntax error
# there is invisible to cargo — it only shows up as a blank panel at runtime
# (the static "waiting for the view artifact" placeholder never gets replaced).
# Extract the script and parse it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 - <<'PY' > /tmp/bar_terminal_script.js
import re
src = open("web/terminal.html").read()
print("\n".join(re.findall(r"<script[^>]*>(.*?)</script>", src, re.S)))
PY
node --check /tmp/bar_terminal_script.js
echo "terminal.html script: syntax-ok"

# The VS Code extension is plain JS with no build step: nothing else catches a
# syntax error before VS Code silently fails to activate it.
node --check vscode/extension.js
echo "vscode/extension.js: syntax-ok"
