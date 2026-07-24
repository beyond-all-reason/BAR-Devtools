# BAR Mission Editor (VS Code)

A terminal for the `bar-mission-kit serve` view artifact: the whole form is
rendered server-side; this extension injects it into a webview and posts edit
intents back over loopback HTTP. The `.lua` file stays the source of truth.

## Run

```bash
just bar::mission-serve                # or bar::mission-dev with the game
code --extensionDevelopmentPath="$PWD/bar-mission-kit/vscode"
```

Then `Ctrl+Shift+P` → **BAR: Open Mission Editor**.

Unit dropdowns fill in once the game has published `domains.json`
(automatic when the game runs with the mission bridge widget).
