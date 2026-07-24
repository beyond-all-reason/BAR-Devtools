// BAR Mission Editor: sidebar host + diagnostics for bar-mission-kit serve.
// The form itself is serve's own browser terminal (GET /), iframed — one UI,
// not a themed copy. Diagnostics come from /status: the recognizer's
// `path:line: message` findings mapped onto the missions dir it reports.
const vscode = require("vscode");

let diagnostics;

function activate(context) {
	const serverUrl = () => vscode.workspace.getConfiguration("barMissionEditor").get("serverUrl");

	diagnostics = vscode.languages.createDiagnosticCollection("bar-mission-kit");
	context.subscriptions.push(diagnostics);

	context.subscriptions.push(
		vscode.window.registerWebviewViewProvider("barMissionEditor.form", {
			resolveWebviewView(view) {
				view.webview.options = { enableScripts: true };
				view.webview.html = frame(serverUrl());
			},
		})
	);

	context.subscriptions.push(
		vscode.commands.registerCommand("barMissionEditor.open", () =>
			vscode.commands.executeCommand("barMissionEditor.form.focus")
		)
	);

	const timer = setInterval(() => {
		const server = serverUrl();
		pollDiagnostics(server);
		pollOpenTarget(server);
	}, 1500);
	context.subscriptions.push({ dispose: () => clearInterval(timer) });
}

// Window routing: serve publishes a sequenced open target; every window's
// extension polls it, but only the window whose workspace contains the file
// acts. First sighting is recorded, not acted on — a freshly opened window
// must not jump to a stale target.
let lastOpenSeq = null;

async function pollOpenTarget(server) {
	let target;
	try {
		const response = await fetch(server + "/open_request");
		if (!response.ok) return;
		target = await response.json();
	} catch {
		return;
	}
	if (typeof target.seq !== "number") return;
	if (lastOpenSeq === null) {
		lastOpenSeq = target.seq;
		return;
	}
	if (target.seq === lastOpenSeq) return;
	lastOpenSeq = target.seq;
	const uri = vscode.Uri.file(target.file);
	if (!vscode.workspace.getWorkspaceFolder(uri)) return; // another window's project
	const row = Math.max(0, (target.line || 1) - 1);
	vscode.window.showTextDocument(uri, {
		preview: false,
		selection: new vscode.Range(row, 0, row, 0),
	});
}

function frame(server) {
	return `<!DOCTYPE html><html>
<head>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src ${server}; style-src 'unsafe-inline';"/>
<style>html, body, iframe { margin: 0; padding: 0; width: 100%; height: 100%; border: 0; overflow: hidden; }</style>
</head>
<body><iframe src="${server}/?embed=1"></iframe></body></html>`;
}

async function pollDiagnostics(server) {
	let status;
	try {
		const response = await fetch(server + "/status");
		if (!response.ok) return;
		status = await response.json();
	} catch {
		return; // serve not running; keep whatever was last shown
	}
	diagnostics.clear();
	if (status.ok || !status.missions_dir) {
		return;
	}
	const byFile = new Map();
	for (const line of String(status.message).split("\n")) {
		// Recognizer findings are `rel/path.lua:line: message`; other status
		// text (rejected edits) doesn't match and stays out of the editor.
		const match = line.match(/^(.*?\.lua):(\d+): (.*)$/);
		if (!match) continue;
		const [, rel, lineNumber, message] = match;
		const row = Math.max(0, Number(lineNumber) - 1);
		const uri = vscode.Uri.joinPath(vscode.Uri.file(status.missions_dir), rel);
		const diagnostic = new vscode.Diagnostic(
			new vscode.Range(row, 0, row, 999),
			message,
			vscode.DiagnosticSeverity.Error
		);
		diagnostic.source = "bar-mission-kit";
		const key = uri.toString();
		if (!byFile.has(key)) byFile.set(key, { uri, list: [] });
		byFile.get(key).list.push(diagnostic);
	}
	for (const { uri, list } of byFile.values()) {
		diagnostics.set(uri, list);
	}
}

function deactivate() {}

module.exports = { activate, deactivate };
