// BAR Mission Editor: sidebar host + diagnostics for bar-mission-kit serve.
// The form itself is serve's own browser terminal (GET /), iframed — one UI,
// not a themed copy. Diagnostics come from /status: the recognizer's
// `path:line: message` findings mapped onto the missions dir it reports.
const vscode = require("vscode");

let diagnostics;

function activate(context) {
	const serverUrl = () => vscode.workspace.getConfiguration("barMissionEditor").get("serverUrl");

	log = vscode.window.createOutputChannel("BAR Mission Editor");
	context.subscriptions.push(log);
	note(`activated; polling ${serverUrl()}`);
	note(`workspace roots: ${workspaceRoots().map(([alias, real]) => (alias === real ? alias : `${alias} -> ${real}`)).join(" | ") || "(none)"}`);

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
					views.set(id, { view, focus });
					view.webview.html = paint(serverUrl(), focus);
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
		),
		// Ctrl+Z has to be claimed by the extension, not by the page. The form
		// is an iframe inside a webview: it only sees a keystroke while it has
		// focus, and VS Code binds Ctrl+Z to its own undo regardless. Declaring
		// the keybinding with `when: focusedView == barMissionEditor.form`
		// takes it while the panel is focused and leaves the editor's undo
		// alone everywhere else. Posting straight to serve, because that is the
		// same channel the page itself uses.
		vscode.commands.registerCommand("barMissionEditor.undo", async () => {
			try {
				await fetch(serverUrl() + "/undo", { method: "POST" });
			} catch (err) {
				note(`undo failed: ${err}`);
			}
		})
	);

	const timer = setInterval(async () => {
		const server = serverUrl();
		const up = await reachable(server);
		if (!up) await ensureServing(server);
		if (up !== serverUp) {
			serverUp = up;
			note(up ? `serve reachable at ${server}` : `serve unreachable at ${server}`);
			// An unreachable server is a blank panel otherwise, which reads as
			// the extension being broken rather than serve not running.
			for (const { view, focus } of views.values()) {
				view.webview.html = paint(server, focus);
			}
		}
		if (!up) return;
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
let lastOpenId = null;
let serverUp = null;
let owned = null;
let blocked = null; // why there is no server, in the user's words
let log = null;
const note = (m) => log && log.appendLine(`${new Date().toISOString().slice(11, 19)}  ${m}`);
const views = new Map();
const startedAt = Date.now();

const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawn } = require("child_process");

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
	if (typeof target.seq !== "number" || typeof target.ts !== "number") return;
	// Identity is the timestamp, not the sequence: serve restarts reset seq to
	// zero, so a click after a restart can reuse a number this host already
	// recorded and be dropped as "unchanged". ts also dates the request, which
	// is what tells a live click from an artifact left by an earlier serve.
	const id = `${target.ts}:${target.seq}`;
	const seen = id === lastOpenId;
	lastOpenId = id;
	if (seen) return;
	if (target.ts <= startedAt) {
		note(`ignoring ${target.file}:${target.line} — written before this window opened`);
		return;
	}
	note(`open request ${target.file}:${target.line}`);
	const routed = routeIntoWorkspace(target.file);
	if (!routed) {
		// Silence here reads as "the button is broken".
		note(`  not in this window; roots: ${workspaceRoots().map(([, real]) => real).join(", ")}`);
		return;
	}
	note(`  opening ${routed}`);
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

// --- serving ---------------------------------------------------------------
// The point of this extension is that BAR-Devtools is not required, so it can
// start the server itself. It ADOPTS first and only spawns when nothing
// answers: one server feeds this panel, the browser terminal and the in-game
// view, and a second writer into the same .editor directory would race the
// first over edit intents.

/// The bundled binary, then anything the user pointed at, then PATH.
function serverBinary() {
	const configured = vscode.workspace.getConfiguration("barMissionEditor").get("serverPath");
	if (configured) return configured;
	const exe = process.platform === "win32" ? "bar-mission-kit.exe" : "bar-mission-kit";
	const bundled = path.join(__dirname, "server", exe);
	return fs.existsSync(bundled) ? bundled : exe;
}

/// Where the game reads the artifact from. serve must write there, or the
/// in-game panel sees nothing; falls back to the mission tree when no install
/// is present.
function editorDir(missionsRoot) {
	const configured = vscode.workspace.getConfiguration("barMissionEditor").get("writeDir");
	const candidates = configured
		? [configured]
		: [
				path.join(os.homedir(), ".local", "state", "Beyond All Reason"),
				path.join(os.homedir(), "Documents", "Beyond All Reason"),
				process.env.LOCALAPPDATA ? path.join(process.env.LOCALAPPDATA, "Beyond All Reason") : null,
			].filter(Boolean);
	for (const base of candidates) {
		if (fs.existsSync(base)) return path.join(base, "modules", "missions", ".editor");
	}
	return path.join(missionsRoot, ".editor");
}

/// A missions root the server can watch. The panel is often open in a window
/// that is not the game repo — docs, devtools, a mission checkout — and one
/// server serves them all, so look wider than this workspace: what the user
/// configured, then inside each folder, then beside it, then the install.
function missionsRoot() {
	const configured = vscode.workspace.getConfiguration("barMissionEditor").get("missionsRoot");
	if (configured) return fs.existsSync(configured) ? configured : null;
	const dirs = (base) => {
		try {
			return fs
				.readdirSync(base, { withFileTypes: true })
				.filter((e) => e.isDirectory() || e.isSymbolicLink())
				.map((e) => path.join(base, e.name));
		} catch {
			return [];
		}
	};
	const candidates = [];
	for (const folder of vscode.workspace.workspaceFolders || []) {
		const here = folder.uri.fsPath;
		candidates.push(here, ...dirs(here));
		// Siblings: BAR, the docs and the devtools usually live side by side,
		// and the window with the panel open is as often one of the others.
		const parent = path.dirname(here);
		if (parent !== here && parent !== path.dirname(parent)) candidates.push(...dirs(parent));
	}
	candidates.push(
		path.join(os.homedir(), ".local", "state", "Beyond All Reason"),
		path.join(os.homedir(), "Documents", "Beyond All Reason"),
	);
	for (const base of candidates) {
		const root = path.join(base, "modules", "missions");
		if (fs.existsSync(root)) return root;
	}
	return null;
}

async function ensureServing(server) {
	if (await reachable(server)) return;
	if (owned) return; // already starting or running ours
	const root = missionsRoot();
	if (!root) {
		blocked = "No modules/missions found in or beside this workspace.";
		note(`${blocked} Set barMissionEditor.missionsRoot to point at one.`);
		repaint(server);
		return;
	}
	const bin = serverBinary();
	const args = ["serve", "--missions-root", root, "--editor-dir", editorDir(root)];
	blocked = null;
	note(`starting ${bin} ${args.join(" ")}`);
	try {
		owned = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
	} catch (e) {
		blocked = `Could not start the bundled server: ${e.message}`;
		note(blocked);
		owned = null;
		repaint(server);
		return;
	}
	owned.on("error", (e) => {
		blocked = `The bundled server failed to start: ${e.message}`;
		note(`${blocked} — set barMissionEditor.serverPath, or run just bar::mission-serve`);
		owned = null;
		repaint(server);
	});
	owned.on("exit", (code) => {
		note(`server exited (${code})`);
		owned = null;
	});
	for (const stream of [owned.stdout, owned.stderr]) {
		stream.on("data", (d) => String(d).trimEnd().split("\n").forEach((l) => note(`  ${l}`)));
	}
}

// Any answer means serve is listening; only a transport error means it is not.
async function reachable(server) {
	try {
		await fetch(server + "/open_request");
		return true;
	} catch {
		return false;
	}
}

function repaint(server) {
	for (const { view, focus } of views.values()) view.webview.html = paint(server, focus);
}

function paint(server, focus) {
	return serverUp === false ? waitingFrame(server) : frame(server, focus);
}

// Names the command and the directory to run it in, because "nothing here" is
// not an actionable message.
function waitingFrame(server) {
	return `<!DOCTYPE html><html>
<head>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline';"/>
<style>
 body { margin: 0; padding: 14px; font-family: var(--vscode-font-family); font-size: var(--vscode-font-size);
        color: var(--vscode-foreground); background: var(--vscode-sideBar-background); }
 h3 { margin: 0 0 6px; font-size: 1em; }
 p { margin: 0 0 10px; color: var(--vscode-descriptionForeground); }
 code { display: block; padding: 7px 9px; border-radius: 4px; user-select: all;
        background: var(--vscode-textCodeBlock-background); font-family: var(--vscode-editor-font-family); }
 small { color: var(--vscode-descriptionForeground); }
</style>
</head>
<body>
 <h3>${blocked ? "The mission editor cannot start" : "Starting the mission editor…"}</h3>
 <p>${blocked || "This extension ships its own server; it should answer in a moment."}</p>
 ${blocked ? "<p>Or start one yourself, in <strong>BAR-Devtools</strong>:</p><code>just bar::mission-serve</code><p></p>" : ""}
 <small>Watching ${server} — this panel opens as soon as it answers.</small>
</body></html>`;
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
	// Structured findings carry the byte span of the token at fault, so the
	// squiggle sits under the bad name instead of the whole line. EmmyLua sees
	// only a string there and has nothing to say; this is our layer over it.
	for (const finding of status.findings || []) {
		const uri = vscode.Uri.joinPath(vscode.Uri.file(status.missions_dir), finding.path);
		const doc = vscode.workspace.textDocuments.find((d) => d.uri.fsPath === uri.fsPath);
		const row = Math.max(0, Number(finding.line) - 1);
		let range = new vscode.Range(row, 0, row, 999);
		if (doc && typeof finding.start === "number" && typeof finding.end === "number") {
			const map = byteToCharOffsets(doc.getText());
			const at = (byte) => doc.positionAt(map ? map[Math.min(byte, map.length - 1)] : byte);
			range = new vscode.Range(at(finding.start), at(finding.end));
		}
		const diagnostic = new vscode.Diagnostic(range, finding.message, vscode.DiagnosticSeverity.Warning);
		diagnostic.source = "bar-mission-kit";
		const key = uri.toString();
		if (!byFile.has(key)) byFile.set(key, { uri, list: [] });
		byFile.get(key).list.push(diagnostic);
	}
	// Older serve, or status text that is not a finding: fall back to the
	// line-wide reading of the message.
	for (const line of (status.findings || []).length ? [] : String(status.message).split("\n")) {
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

function deactivate() {
	// Only ours: an adopted server outlives this window, and the in-game panel
	// may still be reading from it.
	if (owned) {
		owned.kill();
		owned = null;
	}
}

module.exports = { activate, deactivate };
