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

	// Two views over one served form: the mission editor opens on triggers and
	// units, the module editor on the module explorer. Same page, different
	// section focused — terminals stay blind, the URL carries the scope.
	for (const [id, focus] of [["barMissionEditor.form", ""], ["barMissionEditor.modules", "modules"]]) {
		context.subscriptions.push(
			vscode.window.registerWebviewViewProvider(id, {
				resolveWebviewView(view) {
					view.webview.options = { enableScripts: true };
					view.webview.html = frame(serverUrl(), focus);
				},
			})
		);
	}

	context.subscriptions.push(
		vscode.commands.registerCommand("barMissionEditor.open", () =>
			vscode.commands.executeCommand("barMissionEditor.form.focus")
		),
		vscode.commands.registerCommand("barMissionEditor.openModules", () =>
			vscode.commands.executeCommand("barMissionEditor.modules.focus")
		)
	);

	const timer = setInterval(() => {
		const server = serverUrl();
		pollDiagnostics(server);
		pollOpenTarget(server);
		paintEdges(server);
	}, 1500);
	context.subscriptions.push({ dispose: () => clearInterval(timer) });
	context.subscriptions.push(
		vscode.window.onDidChangeActiveTextEditor(() => paintEdges(serverUrl()))
	);
	context.subscriptions.push(edgeDecoration);

	// Trigger files are DSL documents, not Lua project members: their
	// completion comes from serve's vocabulary (surface + objectives +
	// domains), ranked above whatever a Lua LS thinks the world contains.
	context.subscriptions.push(
		vscode.languages.registerCompletionItemProvider(
			{ language: "lua", pattern: "**/modules/missions/**/triggers/**" },
			{
				async provideCompletionItems() {
					const vocab = await vocabulary(serverUrl());
					if (!vocab) return [];
					const items = [];
					const add = (label, insert, kind, sort, detail) => {
						const item = new vscode.CompletionItem(label, kind);
						item.insertText = insert;
						item.sortText = sort;
						item.detail = detail;
						items.push(item);
					};
					const chain = new vscode.CompletionItem("When … Do …", vscode.CompletionItemKind.Snippet);
					chain.insertText = new vscode.SnippetString("When(${1})\n\t.Do(${2})");
					chain.sortText = "00";
					chain.detail = "new trigger chain";
					items.push(chain);
					vocab.conditions.forEach((c, i) =>
						add(`WHEN · ${c.label}`, c.template, vscode.CompletionItemKind.Event, `01${i}`, c.template));
					vocab.effects.forEach((e, i) =>
						add(`DO · ${e.label}`, e.template, vscode.CompletionItemKind.Method, `02${i}`, e.template));
					vocab.objectives.forEach((o, i) =>
						add(o, o, vscode.CompletionItemKind.EnumMember, `03${i}`, "objective"));
					vocab.units.forEach((u, i) =>
						add(u.label, u.value, vscode.CompletionItemKind.Constant, `04${String(i).padStart(3, "0")}`, "unit def"));
					return items;
				},
			}
		)
	);
}

let vocabCache = { at: 0, value: null };
async function vocabulary(server) {
	if (Date.now() - vocabCache.at < 10000 && vocabCache.value) return vocabCache.value;
	try {
		const response = await fetch(server + "/view");
		if (!response.ok) return vocabCache.value;
		const view = await response.json();
		vocabCache = { at: Date.now(), value: view.vocabulary || null };
	} catch {
		// serve down: keep whatever we had
	}
	return vocabCache.value;
}

// Window routing: serve publishes a sequenced open target; every window's
// extension polls it, but only the window whose workspace contains the file
// acts. A target older than this extension host is stale (leftover from a
// previous session) and is recorded without acting; anything stamped after
// we started is a live request, so the first click after a reload still
// opens — seq alone cannot tell these apart, since it resets with serve.
let lastOpenSeq = null;
const startedAt = Date.now();

const fs = require("fs");
const path = require("path");

function realpath(p) {
	try {
		return fs.realpathSync(p);
	} catch {
		return p;
	}
}

// Workspace roots plus one level of symlinked children, as [alias, real]
// pairs — multi-repo layouts (BAR-Devtools) link sibling repos into the
// workspace, and atomic distros alias /home to /var/home.
function workspaceRoots() {
	const roots = [];
	for (const folder of vscode.workspace.workspaceFolders || []) {
		const base = folder.uri.fsPath;
		roots.push([base, realpath(base)]);
		let entries = [];
		try {
			entries = fs.readdirSync(base, { withFileTypes: true });
		} catch {}
		for (const entry of entries) {
			if (!entry.isSymbolicLink()) continue;
			const alias = path.join(base, entry.name);
			roots.push([alias, realpath(alias)]);
		}
	}
	return roots;
}

// serve publishes canonical paths; VS Code's getWorkspaceFolder is a textual,
// symlink-blind match. Route by RESOLVED prefixes instead, and open through
// the matching alias so the file lands inside this window's tree.
function routeIntoWorkspace(file) {
	const target = realpath(file);
	for (const [alias, real] of workspaceRoots()) {
		if (target === real || target.startsWith(real + path.sep)) {
			return path.join(alias, path.relative(real, target));
		}
	}
	return null;
}

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
		if (!(typeof target.ts === "number" && target.ts > startedAt)) return;
	}
	if (target.seq === lastOpenSeq && !(typeof target.ts === "number" && target.ts > startedAt)) return;
	lastOpenSeq = target.seq;
	const routed = routeIntoWorkspace(target.file);
	if (!routed) return; // another window's project
	const row = Math.max(0, (target.line || 1) - 1);
	vscode.window.showTextDocument(vscode.Uri.file(routed), {
		preview: false,
		selection: new vscode.Range(row, 0, row, 0),
	});
}

// The surface's edge, painted from the published AST: everything the
// recognizer classified as opaque is OUTSIDE the mission subset — it runs as
// plain Lua and no mission tooling sees it. emmylua keeps its highlighting;
// this overlay only marks the boundary. Spans are byte offsets into the
// exact bytes the AST was built from, so painting is gated on the content
// hash — a dirty or stale buffer clears instead of lying.
const edgeDecoration = vscode.window.createTextEditorDecorationType({
	backgroundColor: "rgba(224, 108, 117, 0.07)",
	textDecoration: "underline dashed rgba(224, 108, 117, 0.55) 1px",
});

function fnv1a(text) {
	const bytes = Buffer.from(text, "utf8");
	let hash = 0xcbf29ce484222325n;
	for (const b of bytes) {
		hash ^= BigInt(b);
		hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
	}
	return hash.toString(16).padStart(16, "0");
}

// Byte offset -> UTF-16 character offset (identity for ASCII files).
function byteToCharOffsets(text) {
	const byteLength = Buffer.byteLength(text, "utf8");
	if (byteLength === text.length) return null; // ASCII: offsets coincide
	const map = new Array(byteLength + 1);
	let byte = 0;
	for (let i = 0; i < text.length; i++) {
		const width = Buffer.byteLength(text[i], "utf8");
		for (let k = 0; k < width; k++) map[byte + k] = i;
		byte += width;
	}
	map[byte] = text.length;
	return map;
}

let edgeCache = { generation: null, docVersion: null, uri: null };

async function paintEdges(server) {
	const editor = vscode.window.activeTextEditor;
	if (!editor) return;
	const doc = editor.document;
	if (doc.languageId !== "lua" || !/\/modules\/missions\//.test(doc.uri.fsPath)) return;

	let ast;
	try {
		const response = await fetch(server + "/ast");
		if (!response.ok) return;
		ast = await response.json();
	} catch {
		return;
	}
	if (
		edgeCache.generation === ast.generation &&
		edgeCache.docVersion === doc.version &&
		edgeCache.uri === doc.uri.toString()
	) {
		return;
	}
	edgeCache = { generation: ast.generation, docVersion: doc.version, uri: doc.uri.toString() };

	const file = (ast.files || []).find((f) => doc.uri.fsPath.endsWith("/" + f.path));
	const text = doc.getText();
	if (!file || doc.isDirty || fnv1a(text) !== file.hash) {
		editor.setDecorations(edgeDecoration, []);
		return;
	}
	const map = byteToCharOffsets(text);
	const at = (byte) => doc.positionAt(map ? map[Math.min(byte, map.length - 1)] : byte);
	const decorations = (file.opaque || []).map((o) => ({
		range: new vscode.Range(at(o.span[0]), at(o.span[1])),
		hoverMessage: `outside the mission surface: ${o.reason} — this runs as plain Lua; no mission tooling sees it`,
	}));
	editor.setDecorations(edgeDecoration, decorations);
}

function frame(server, focus) {
	const scope = focus ? `&focus=${encodeURIComponent(focus)}` : "";
	return `<!DOCTYPE html><html>
<head>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src ${server}; style-src 'unsafe-inline';"/>
<style>html, body, iframe { margin: 0; padding: 0; width: 100%; height: 100%; border: 0; overflow: hidden; }</style>
</head>
<body><iframe src="${server}/?embed=1${scope}"></iframe></body></html>`;
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
