//! bar-mission-kit: the mission DSL recognizer + validator CLI.
//!
//! One grammar, two consumers:
//!   parse  — emit the decorated mission AST as JSON (the RML form's input,
//!            and later the write-back layer's document model)
//!   check  — same walk, findings only; nonzero exit on a non-conforming
//!            mission (CI's validator)

mod graph;
mod http;
mod model;
mod recognizer;
mod serve;
mod types;
mod view;

use clap::{Parser, Subcommand};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

#[derive(Parser)]
#[command(name = "bar-mission-kit", about = "Mission DSL recognizer/validator")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Emit the decorated mission AST as JSON.
    Parse {
        /// Mission trigger files, or directories to scan for triggers/*.lua
        paths: Vec<PathBuf>,
        /// Write JSON here instead of stdout
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// Validate mission files; print findings, exit nonzero on any.
    Check { paths: Vec<PathBuf> },
    /// Run the editor service: watch missions, regenerate the AST artifact,
    /// apply UI edit intents, handle open-in-editor requests.
    Serve {
        /// Mission directory to watch (e.g. .../modules/missions/hello_pawns).
        /// Optional with --missions-root.
        missions_dir: Option<PathBuf>,
        /// Follow the game: watch this missions root and re-scope to whatever
        /// mission the game arms (active_mission.json from the bridge).
        #[arg(long)]
        missions_root: Option<PathBuf>,
        /// Directory for the artifact + edits/ + open_request.json
        #[arg(long)]
        editor_dir: PathBuf,
        /// Shell template for open-in-editor. Empty (the default) means the
        /// VS Code extension owns opening: it routes to the window whose
        /// workspace contains the mission. Set e.g. "code -g {file}:{line}"
        /// for extension-less setups.
        #[arg(long, default_value = "")]
        editor_cmd: String,
        /// Loopback HTTP address for editor clients (VS Code webview)
        #[arg(long, default_value = "127.0.0.1:8571")]
        listen: String,
    },
}

/// Record the port actually bound, so a client can find a serve that had to
/// move aside. Written next to everything else the editor dir already carries.
fn announce_port(editor_dir: &std::path::Path, port: u16) {
    let _ = std::fs::create_dir_all(editor_dir);
    let _ = std::fs::write(
        editor_dir.join("serve_port.json"),
        format!("{{\"port\":{port},\"pid\":{}}}", std::process::id()),
    );
}

fn collect_lua_files(paths: &[PathBuf]) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for path in paths {
        if path.is_dir() {
            // The loader's contract: a mission is its triggers/ dir plus an
            // optional units.lua roster. Scanning wider (missions root mode)
            // must not recognize lib/gadget code.
            for pattern in [
                format!("{}/**/triggers/*.lua", path.display()),
                format!("{}/**/units.lua", path.display()),
                format!("{}/**/objectives.lua", path.display()),
                format!("{}/**/modes/*.lua", path.display()),
            ] {
                for entry in glob::glob(&pattern).expect("valid glob").flatten() {
                    // spec/modes/, spec/**/triggers/ etc. are busted's, not ours.
                    // actions/ is the framework's action slot, and a module
                    // whose action happens to be called units.lua is not a
                    // mission roster — transfer has exactly that.
                    if entry
                        .components()
                        .any(|c| c.as_os_str() == "spec" || c.as_os_str() == "actions")
                    {
                        continue;
                    }
                    // modules/modes is a MODULE (mode infrastructure); its own
                    // files aren't presets. Presets live in <module>/modes/.
                    fn dir_name(p: Option<&std::path::Path>) -> &str {
                        p.and_then(|d| d.file_name())
                            .and_then(|n| n.to_str())
                            .unwrap_or("")
                    }
                    let parent = entry.parent();
                    if dir_name(parent) == "modes"
                        && dir_name(parent.and_then(|p| p.parent())) == "modules"
                    {
                        continue;
                    }
                    files.push(entry);
                }
            }
            let roster = path.join("units.lua");
            if roster.is_file() {
                files.push(roster);
            }
            let objectives = path.join("objectives.lua");
            if objectives.is_file() {
                files.push(objectives);
            }
        } else {
            files.push(path.clone());
        }
    }
    files.sort();
    files.dedup();
    files
}

fn display_path(file: &Path, roots: &[PathBuf]) -> String {
    for root in roots {
        if let Ok(rel) = file.strip_prefix(root) {
            return rel.display().to_string();
        }
    }
    file.display().to_string()
}

/// Every verb a module publishes becomes a palette entry, with the example call
/// built from its signature. Labels and compositions come from the overlay;
/// nothing here is a second copy of the vocabulary.
fn palette(
    overlay: &mut serde_json::Map<String, serde_json::Value>,
    types: &types::TypeSurface,
    modules: &[types::ModuleInfo],
) {
    let labels: std::collections::BTreeMap<String, String> = overlay
        .get("labels")
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .unwrap_or_default();
    let derived = types.roles();
    for (role, paths) in [
        (
            "conditions",
            if modules.is_empty() {
                derived.conditions.clone()
            } else {
                modules
                    .iter()
                    .flat_map(|m| m.conditions.iter().cloned())
                    .collect()
            },
        ),
        (
            "effects",
            if modules.is_empty() {
                derived.effects.clone()
            } else {
                modules
                    .iter()
                    .flat_map(|m| m.effects.iter().cloned())
                    .collect()
            },
        ),
    ] {
        let mut entries: Vec<serde_json::Value> = Vec::new();
        for path in paths {
            let Some(template) = types.template_for(&path) else {
                continue;
            };
            entries.push(serde_json::json!({
                "label": labels.get(&path).cloned().unwrap_or_else(|| humanize(&path)),
                "template": template,
            }));
        }
        if let Some(extra) = overlay.get(role).and_then(|v| v.as_array()) {
            entries.extend(extra.iter().cloned());
        }
        overlay.insert(role.into(), serde_json::Value::Array(entries));
    }
}

/// "Transfer.Units" -> "Transfer units". A label the overlay does not override.
fn humanize(path: &str) -> String {
    let mut words: Vec<String> = Vec::new();
    for (i, segment) in path.split('.').enumerate() {
        let mut current = String::new();
        for (j, ch) in segment.char_indices() {
            if ch.is_uppercase() && j > 0 {
                words.push(std::mem::take(&mut current));
            }
            current.push(if i == 0 && j == 0 {
                ch
            } else {
                ch.to_ascii_lowercase()
            });
        }
        words.push(current);
    }
    words.retain(|w| !w.is_empty());
    words.join(" ")
}

pub(crate) const MISSION_SURFACE: &str = include_str!("../surfaces/missions.json");

pub fn collect_ast(paths: &[PathBuf], generation: u64) -> (model::MissionAst, Vec<model::Finding>) {
    let files = collect_lua_files(paths);
    // The grammar's source of truth: the game's LuaCATS types. Resolution is
    // PER FILE — each file answers to its own module's published surface
    // (nearest marked types/ dir), so a sharing mode preset and a mission
    // trigger file check against different vocabularies in one walk.
    let mut surfaces: std::collections::HashMap<
        (PathBuf, &'static str),
        std::rc::Rc<types::TypeSurface>,
    > = std::collections::HashMap::new();
    let mut surface_for = |file: &PathBuf| -> std::rc::Rc<types::TypeSurface> {
        // A preset and a trigger file can live in one module and are written in
        // different vocabularies, so the policy is part of the cache key. Keyed
        // on the types dir alone, whichever kind was seen first would answer
        // for both — and the other would be checked against the wrong grammar.
        let policy = match recognizer::FileKind::of(&file.to_string_lossy()) {
            recognizer::FileKind::ModePreset => "mode",
            // The board's grammar rides the trigger policy surface: the same
            // metas declare Objective and the declaration class.
            recognizer::FileKind::Statements
            | recognizer::FileKind::Objectives
            | recognizer::FileKind::Variables => "trigger",
        };
        let key = types::TypeSurface::types_dir_near_policy(file, policy)
            .unwrap_or_else(|| PathBuf::from("<builtin>"));
        surfaces
            .entry((key, policy))
            .or_insert_with(|| {
                std::rc::Rc::new(types::TypeSurface::load_near_policy(
                    std::slice::from_ref(file),
                    policy,
                ))
            })
            .clone()
    };

    let mut surface: serde_json::Value =
        serde_json::from_str(MISSION_SURFACE).expect("valid surface overlay");
    let mut ast = model::MissionAst {
        version: 1,
        generation,
        files: Vec::new(),
        surface: serde_json::Value::Null,
    };
    let mut findings = Vec::new();
    let mut enums: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    for file in &files {
        let rel = display_path(file, paths);
        let source = match std::fs::read_to_string(file) {
            Ok(s) => s,
            Err(e) => {
                findings.push(model::Finding {
                    path: rel,
                    line: 0,
                    message: format!("cannot read: {e}"),
                    span: None,
                });
                continue;
            }
        };
        let type_surface = surface_for(file);
        enums.extend(type_surface.enums());
        match recognizer::recognize_file_with(&rel, &source, &type_surface) {
            Ok(recognized) => {
                findings.extend(recognized.findings);
                ast.files.push(recognized.file);
            }
            Err(e) => findings.push(model::Finding {
                path: rel,
                line: 0,
                message: format!("parse error: {e}"),
                span: None,
            }),
        }
    }
    if let Some(overlay) = surface.as_object_mut() {
        // Derived editor enums ride the artifact so every terminal renders
        // literal-union parameters as pickers.
        overlay.insert(
            "enums".into(),
            serde_json::to_value(enums).expect("serializable enums"),
        );
        // The module explorer: every module publishing a marked surface,
        // discovered the same way the grammar is.
        if let Some(root) = files
            .first()
            .and_then(|f| types::TypeSurface::types_dir_near(f))
            .and_then(|t| t.parent().and_then(|m| m.parent()).map(|p| p.to_path_buf()))
        {
            let modules = types::explore_modules(&root);
            palette(overlay, &types::TypeSurface::load_near(&files), &modules);
            overlay.insert(
                "modules".into(),
                serde_json::to_value(modules).expect("serializable modules"),
            );
        }
    }
    if surface
        .get("conditions")
        .and_then(|v| v.as_array())
        .is_none_or(|a| a.is_empty())
    {
        // No modules tree in reach (a mission opened on its own): derive the
        // palette from the types the kit mirrors, so the editor is still usable.
        if let Some(overlay) = surface.as_object_mut() {
            palette(overlay, types::TypeSurface::builtin(), &[]);
        }
    }
    if let Some(overlay) = surface.as_object_mut() {
        overlay.insert("handles".into(), handle_palette(&ast.files));
    }
    ast.surface = surface;
    findings.extend(cross_check_names(&ast.files));
    (ast, findings)
}

/// The conventional alias for a definition file: what the palette writes and
/// what serve imports when a row references a file the target has not included.
pub(crate) fn alias_for(path: &str) -> Option<&'static str> {
    let base = path.rsplit(['/', '\\']).next()?;
    match base {
        "units.lua" => Some("Units"),
        "objectives.lua" => Some("Objectives"),
        "variables.lua" => Some("Variables"),
        _ => None,
    }
}

/// This mission's own vocabulary: every exported handle, with the verbs its
/// class offers, as palette rows — `Units.hub.IsDestroyed()`,
/// `Objectives.relieve.Complete()`. Derived from the exports and the types;
/// nothing here knows what kinds of handle exist.
fn handle_palette(files: &[model::FileAst]) -> serde_json::Value {
    let mut conditions = Vec::new();
    let mut effects = Vec::new();
    for file in files {
        if !recognizer::is_definition_site(&file.path, "units.lua")
            && !recognizer::is_definition_site(&file.path, "objectives.lua")
            && !recognizer::is_definition_site(&file.path, "variables.lua")
        {
            continue;
        }
        let Some(alias) = alias_for(&file.path) else {
            continue;
        };
        let surface = types::TypeSurface::builtin();
        for export in &file.exports {
            let Some(class) = &export.class else {
                continue;
            };
            for (verb, role, args) in surface.handle_verbs(class) {
                let entry = serde_json::json!({
                    "label": format!("{}.{} {}", alias, export.key, humanize(&verb).to_lowercase()),
                    "template": format!("{alias}.{}.{verb}{args}", export.key),
                });
                match role {
                    "condition" => conditions.push(entry),
                    _ => effects.push(entry),
                }
            }
        }
    }
    serde_json::json!({ "conditions": conditions, "effects": effects })
}

/// Cross-file noun check: every Unit()/Units reference must name something
/// units.lua declared. Only meaningful when a roster was walked — a partial
/// (single-file) invocation stays quiet.
fn cross_check_names(files: &[model::FileAst]) -> Vec<model::Finding> {
    let mut findings = Vec::new();
    if files.iter().any(|f| f.path.ends_with("units.lua")) {
        findings.extend(cross_check_units(files));
    }
    // Objective ids get the same contract once a definition site exists:
    // objectives.lua declares, everything else references — the runtime
    // fails these loads, so check mode reports them.
    findings.extend(cross_check_exports(files));
    if files.iter().any(|f| recognizer::is_objectives(&f.path)) {
        let objective_defs: std::collections::HashSet<&str> = files
            .iter()
            .flat_map(|f| f.objective_defs.iter().map(String::as_str))
            .collect();
        for file in files {
            for r in &file.objective_refs {
                if !objective_defs.contains(r.name.as_str()) {
                    findings.push(model::Finding {
                        path: file.path.clone(),
                        line: r.line,
                        message: format!(
                            "Objective(\"{}\"): objectives.lua declares no such objective",
                            r.name
                        ),
                        span: None,
                    });
                }
            }
        }
    }
    findings
}

/// Exports are the other half of the contract: `Units.hub` through
/// `local Units = VFS.Include(".../units.lua")` must name something that file
/// returned. The included file is matched by its last two path components,
/// since the walk's paths are mission-relative and the include's are not.
fn cross_check_exports(files: &[model::FileAst]) -> Vec<model::Finding> {
    fn tail(path: &str) -> String {
        let parts: Vec<&str> = path
            .split(|c| c == '/' || c == '\\')
            .filter(|p| !p.is_empty())
            .collect();
        parts
            .iter()
            .rev()
            .take(2)
            .rev()
            .cloned()
            .collect::<Vec<_>>()
            .join("/")
    }
    let mut findings = Vec::new();
    for file in files {
        for r in &file.export_refs {
            let wanted = tail(&r.file);
            let Some(target) = files.iter().find(|f| tail(&f.path) == wanted) else {
                continue; // a partial walk: nothing to check against
            };
            let keys: Vec<&str> = target.exports.iter().map(|e| e.key.as_str()).collect();
            if !keys.contains(&r.key.as_str()) {
                findings.push(model::Finding {
                    path: file.path.clone(),
                    line: r.line,
                    message: format!("{}: {} exports no such key", r.key, wanted),
                    span: None,
                });
            }
        }
    }
    findings
}

fn cross_check_units(files: &[model::FileAst]) -> Vec<model::Finding> {
    let unit_defs: std::collections::HashSet<&str> = files
        .iter()
        .flat_map(|f| f.unit_defs.iter().map(String::as_str))
        .collect();
    let group_defs: std::collections::HashSet<&str> = files
        .iter()
        .flat_map(|f| f.group_defs.iter().map(String::as_str))
        .collect();
    let mut findings = Vec::new();
    for file in files {
        for r in &file.unit_refs {
            if !unit_defs.contains(r.name.as_str()) {
                findings.push(model::Finding {
                    path: file.path.clone(),
                    line: r.line,
                    message: format!("Unit(\"{}\"): units.lua declares no such name", r.name),
                    span: None,
                });
            }
        }
        for r in &file.group_refs {
            if !group_defs.contains(r.name.as_str()) {
                findings.push(model::Finding {
                    path: file.path.clone(),
                    line: r.line,
                    message: format!("group \"{}\": units.lua declares no such group", r.name),
                    span: None,
                });
            }
        }
    }
    findings
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.command {
        Command::Parse { paths, out } => {
            let (ast, findings) = collect_ast(&paths, 1);
            for f in &findings {
                eprintln!("{}:{}: {}", f.path, f.line, f.message);
            }
            let json = serde_json::to_string_pretty(&ast).expect("serializable AST");
            match out {
                Some(path) => {
                    if let Err(e) = std::fs::write(&path, json) {
                        eprintln!("cannot write {}: {e}", path.display());
                        return ExitCode::FAILURE;
                    }
                }
                None => println!("{json}"),
            }
            ExitCode::SUCCESS
        }
        Command::Check { paths } => {
            let (_ast, findings) = collect_ast(&paths, 1);
            for f in &findings {
                println!("{}:{}: {}", f.path, f.line, f.message);
            }
            if findings.is_empty() {
                println!("OK");
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        Command::Serve {
            missions_dir,
            missions_root,
            editor_dir,
            editor_cmd,
            listen,
        } => {
            let Some(initial) = missions_dir.or_else(|| missions_root.clone()) else {
                eprintln!("serve needs a missions dir or --missions-root");
                return ExitCode::FAILURE;
            };
            // A taken port is the normal consequence of the VS Code extension
            // already serving this workspace. Silently carrying on without HTTP
            // was the worst of the options: the second process stayed alive,
            // invisible, writing the SAME editor dir as the first, so whichever
            // wrote last won and the panel showed whichever that was.
            match http::try_spawn(&listen, editor_dir.clone()) {
                Ok(port) => announce_port(&editor_dir, port),
                Err(http::BindError::Other) => return ExitCode::FAILURE,
                Err(http::BindError::InUse) => {
                    let ours = editor_dir
                        .canonicalize()
                        .unwrap_or_else(|_| editor_dir.clone());
                    let theirs = http::probe_editor_dir(&listen)
                        .map(std::path::PathBuf::from)
                        .map(|p| p.canonicalize().unwrap_or(p));
                    if theirs.as_deref() == Some(ours.as_path()) {
                        // Same workspace, already served. Doing nothing is the
                        // correct outcome, and it is a success, not a failure —
                        // the caller asked for this directory to be served and
                        // it is being served.
                        eprintln!(
                            "serve: {} is already being served at http://{listen} — nothing to do",
                            ours.display()
                        );
                        return ExitCode::SUCCESS;
                    }
                    // Somebody else's workspace. Step aside onto a free port so
                    // two checkouts can be open at once.
                    match http::try_spawn("127.0.0.1:0", editor_dir.clone()) {
                        Ok(port) => {
                            match theirs {
                                Some(dir) => eprintln!(
                                    "serve: http://{listen} is serving {} — using port {port} instead",
                                    dir.display()
                                ),
                                None => eprintln!(
                                    "serve: http://{listen} is taken by something that is not a mission serve — using port {port} instead"
                                ),
                            }
                            announce_port(&editor_dir, port);
                        }
                        Err(_) => {
                            eprintln!("serve: no free loopback port available");
                            return ExitCode::FAILURE;
                        }
                    }
                }
            }
            serve::Server::new(initial, editor_dir, editor_cmd, missions_root).run()
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::model::Value;

    const WIN: &str = r#"
When(Team.Player.Has(UnitDef("armpw"), 3))
	.Do(Objective("build_pawns").Complete())

When(Objective("build_pawns").IsComplete())
	.Do(MatchFlow.Victory(Team.Player))
"#;

    #[test]
    fn recognizes_the_hello_pawns_mission() {
        let rec = crate::recognizer::recognize_file("triggers/win.lua", WIN).unwrap();
        assert!(rec.findings.is_empty(), "findings: {:?}", rec.findings);
        assert_eq!(rec.file.groups.len(), 1);
        let triggers = &rec.file.groups[0].triggers;
        assert_eq!(triggers.len(), 2);
        assert_eq!(triggers[0].id, "triggers/win.lua:1");
        let steps: Vec<&str> = triggers[0].steps.iter().map(|s| s.verb.as_str()).collect();
        assert_eq!(steps, vec!["When", "Do"]);

        match &triggers[0].steps[0].args[0] {
            Value::Verb { path, calls, .. } => {
                assert_eq!(path, "Team.Player.Has");
                assert_eq!(calls.len(), 1);
                match &calls[0].args[1] {
                    Value::Number { value, .. } => assert_eq!(*value, 3.0),
                    other => panic!("expected count literal, got {other:?}"),
                }
            }
            other => panic!("expected verb condition, got {other:?}"),
        }

        match &triggers[1].steps[1].args[0] {
            Value::Verb { path, calls, .. } => {
                assert_eq!(path, "MatchFlow.Victory");
                match &calls[0].args[0] {
                    Value::Name { path, .. } => assert_eq!(path, "Team.Player"),
                    other => panic!("expected Team.Player ref, got {other:?}"),
                }
            }
            other => panic!("expected verb effect, got {other:?}"),
        }
    }

    const BOARD: &str = r#"
Objective("relieve_the_outpost")
	.Title("Relieve the outpost")
	.CompletedWhen(Unit("hub").IsSpotted(Team.Player))
	.When(Team.Player.Has(UnitDef("corllt"), 4))

Objective("find_the_enclave")
	.Title("Find the Enclave")
	.CompletedWhen(Unit("beacon").IsSpotted(Team.Player))
	.When(Objective("relieve_the_outpost").IsComplete())
"#;

    #[test]
    fn the_board_is_a_definition_site() {
        let rec = crate::recognizer::recognize_file("cm8/objectives.lua", BOARD).unwrap();
        assert!(rec.findings.is_empty(), "findings: {:?}", rec.findings);
        let triggers = &rec.file.groups[0].triggers;
        assert_eq!(triggers.len(), 2);
        let steps: Vec<&str> = triggers[0].steps.iter().map(|s| s.verb.as_str()).collect();
        assert_eq!(steps, vec!["Objective", "Title", "CompletedWhen", "When"]);
        // The head declares; the nested gate references. That split is the
        // whole cross-check.
        assert_eq!(
            rec.file.objective_defs,
            vec!["relieve_the_outpost", "find_the_enclave"]
        );
        let refs: Vec<&str> = rec
            .file
            .objective_refs
            .iter()
            .map(|r| r.name.as_str())
            .collect();
        assert_eq!(refs, vec!["relieve_the_outpost"]);
    }

    #[test]
    fn a_trigger_file_named_objectives_is_still_a_trigger_file() {
        use crate::recognizer::FileKind;
        assert!(FileKind::of("cm8/objectives.lua") == FileKind::Objectives);
        assert!(FileKind::of("cm8/triggers/objectives.lua") == FileKind::Statements);
    }

    #[test]
    fn a_declaration_speaking_an_unknown_verb_is_a_finding() {
        let rec = crate::recognizer::recognize_file(
            "m/objectives.lua",
            "Objective(\"step\")\n\t.Completed(Team.Player.Has(UnitDef(\"armpw\"), 1))\n",
        )
        .unwrap();
        assert!(
            rec.findings
                .iter()
                .any(|f| f.message.contains("unknown chain verb 'Completed'")),
            "findings: {:?}",
            rec.findings
        );
    }

    #[test]
    fn export_references_cross_check_against_what_the_files_return() {
        let board = crate::recognizer::recognize_file(
            "m/objectives.lua",
            "local relieve = Objective(\"relieve_the_outpost\")\nreturn { relieve = relieve }\n",
        )
        .unwrap();
        let roster = crate::recognizer::recognize_file(
            "m/units.lua",
            "local hub = Spawn(UnitDef(\"corlab\"), \"gaia\").At(0.4, 0.4)\nreturn { hub = hub }\n",
        )
        .unwrap();
        let trigger = crate::recognizer::recognize_file(
            "m/triggers/a.lua",
            "local Units = VFS.Include(\"modules/missions/m/units.lua\")\nlocal Objectives = VFS.Include(\"modules/missions/m/objectives.lua\")\nWhen(Units.hub.IsSpotted(Team.Player)).Do(Objectives.relieve.Complete())\nWhen(Units.tower.IsDestroyed()).Do(Objectives.ghost.Complete())\n",
        )
        .unwrap();
        let findings = super::cross_check_names(&[board.file, roster.file, trigger.file]);
        let messages: Vec<&str> = findings.iter().map(|f| f.message.as_str()).collect();
        assert_eq!(messages.len(), 2, "{messages:?}");
        assert!(messages.iter().any(|m| m.starts_with("tower: m/units.lua")));
        assert!(messages
            .iter()
            .any(|m| m.starts_with("ghost: m/objectives.lua")));
    }

    #[test]
    fn objective_refs_cross_check_against_the_board() {
        let board = crate::recognizer::recognize_file(
            "m/objectives.lua",
            "Objective(\"real\")\n\t.Title(\"Real\")\n",
        )
        .unwrap();
        let trigger = crate::recognizer::recognize_file(
            "m/triggers/win.lua",
            "When(Objective(\"ghost\").IsComplete())\n\t.Do(Objective(\"real\").Complete())\n",
        )
        .unwrap();
        let findings = super::cross_check_names(&[board.file, trigger.file]);
        assert_eq!(findings.len(), 1, "findings: {findings:?}");
        assert!(findings[0].message.contains("Objective(\"ghost\")"));
        assert!(findings[0].message.contains("no such objective"));
    }

    #[test]
    fn without_a_board_objective_names_go_unchecked() {
        let trigger = crate::recognizer::recognize_file(
            "m/triggers/win.lua",
            "When(Objective(\"anything\").IsComplete())\n\t.Do(Objective(\"else\").Complete())\n",
        )
        .unwrap();
        assert!(super::cross_check_names(&[trigger.file]).is_empty());
    }

    #[test]
    fn chained_invocations_survive() {
        let src = r#"
When(Region("north").EnteredBy(Team.Player, { count = 5 }))
	.Do(Wave.Define("flank").Route(Path("east")).Spawn())
"#;
        let rec = crate::recognizer::recognize_file("triggers/w.lua", src).unwrap();
        assert!(rec.findings.is_empty(), "findings: {:?}", rec.findings);
        let t = &rec.file.groups[0].triggers[0];
        match &t.steps[1].args[0] {
            Value::Verb { path, calls, .. } => {
                assert_eq!(path, "Wave.Define");
                let names: Vec<Option<&str>> = calls.iter().map(|c| c.name.as_deref()).collect();
                assert_eq!(names, vec![None, Some("Route"), Some("Spawn")]);
            }
            other => panic!("expected verb, got {other:?}"),
        }
    }

    #[test]
    fn function_bodies_are_findings() {
        let src = "When(C()).Do(function() end)\n";
        let rec = crate::recognizer::recognize_file("triggers/bad.lua", src).unwrap();
        assert!(rec
            .findings
            .iter()
            .any(|f| f.message.contains("closure-free")));
    }

    #[test]
    fn non_chain_statements_are_findings() {
        let src = "if true then end\n";
        let rec = crate::recognizer::recognize_file("triggers/bad.lua", src).unwrap();
        assert_eq!(rec.findings.len(), 1);
        assert_eq!(rec.file.opaque.len(), 1);
    }

    #[test]
    fn group_and_label_decorators_shape_the_tree() {
        let src = r#"
---@group("Waves")
---@label("First blood")
When(C()).Do(E())
"#;
        let rec = crate::recognizer::recognize_file("triggers/d.lua", src).unwrap();
        assert_eq!(rec.file.groups.len(), 1);
        assert_eq!(rec.file.groups[0].label.as_deref(), Some("Waves"));
        assert_eq!(
            rec.file.groups[0].triggers[0].label.as_deref(),
            Some("First blood")
        );
    }

    #[test]
    fn semantics_objectives_and_insert_points_are_stamped() {
        let rec = crate::recognizer::recognize_file("triggers/win.lua", WIN).unwrap();
        assert_eq!(rec.file.objectives, vec!["build_pawns".to_string()]);
        let t1 = &rec.file.groups[0].triggers[0];
        match &t1.steps[0].args[0] {
            Value::Verb { calls, .. } => {
                match &calls[0].args[0] {
                    Value::Verb { calls, .. } => match &calls[0].args[0] {
                        Value::String { semantic, .. } => {
                            assert_eq!(semantic.as_deref(), Some("unit_def_name"))
                        }
                        other => panic!("expected unit string, got {other:?}"),
                    },
                    other => panic!("expected UnitDef verb, got {other:?}"),
                }
                match &calls[0].args[1] {
                    Value::Number { semantic, .. } => {
                        assert_eq!(semantic.as_deref(), Some("count"))
                    }
                    other => panic!("expected count, got {other:?}"),
                }
            }
            other => panic!("expected Has verb, got {other:?}"),
        }
        let at = t1.insert_effect_at;
        assert!(
            WIN[..at]
                .trim_end()
                .ends_with(".Do(Objective(\"build_pawns\").Complete())"),
            "{}",
            &WIN[..at]
        );
    }

    #[test]
    fn a_chain_without_do_is_a_finding() {
        let src = "When(C()).Once()\n";
        let rec = crate::recognizer::recognize_file("triggers/r.lua", src).unwrap();
        assert!(rec.findings.iter().any(|f| f.message.contains("no Do")));
    }

    #[test]
    fn a_leftover_register_is_named_explicitly() {
        let src = "When(C()).Do(E()).Register()\n";
        let rec = crate::recognizer::recognize_file("triggers/r.lua", src).unwrap();
        assert!(rec
            .findings
            .iter()
            .any(|f| f.message.contains("Register is gone")));
    }

    #[test]
    fn an_undeclared_statement_verb_is_a_finding() {
        let src = "Spwan(UnitDef(\"corlab\"), \"gaia\").At(0.1, 0.1)\n";
        let rec = crate::recognizer::recognize_file("units.lua", src).unwrap();
        assert!(
            rec.findings
                .iter()
                .any(|f| f.message.contains("unknown statement verb 'Spwan'")
                    && f.message.contains("When")
                    && f.message.contains("Spawn")),
            "{:?}",
            rec.findings
        );
        assert_eq!(rec.file.opaque.len(), 1);
    }

    #[test]
    fn spawn_chains_are_recognized_from_the_types() {
        let src = "Spawn(UnitDef(\"corlab\"), \"gaia\")\n\t.At(0.42, 0.42)\n\t.Named(\"hub\")\n\t.Grouped(\"outpost\")\n";
        let rec = crate::recognizer::recognize_file("units.lua", src).unwrap();
        assert!(rec.findings.is_empty(), "findings: {:?}", rec.findings);
        let steps: Vec<&str> = rec.file.groups[0].triggers[0]
            .steps
            .iter()
            .map(|s| s.verb.as_str())
            .collect();
        assert_eq!(steps, vec!["Spawn", "At", "Named", "Grouped"]);
        assert_eq!(rec.file.unit_defs, vec!["hub".to_string()]);
        assert_eq!(rec.file.group_defs, vec!["outpost".to_string()]);
        assert!(rec.file.unit_refs.is_empty());
        match &rec.file.groups[0].triggers[0].steps[0].args[1] {
            Value::String { semantic, .. } => assert_eq!(semantic.as_deref(), Some("team_role")),
            other => panic!("expected team role string, got {other:?}"),
        }
    }

    #[test]
    fn a_spawn_without_at_is_a_finding_and_unknown_chain_verbs_name_the_chain() {
        let src = "Spawn(UnitDef(\"corlab\"), \"gaia\").Armed(true)\n";
        let rec = crate::recognizer::recognize_file("units.lua", src).unwrap();
        assert!(
            rec.findings.iter().any(|f| f.message.contains("no At")),
            "{:?}",
            rec.findings
        );
        assert!(
            rec.findings
                .iter()
                .any(|f| f.message.contains("unknown chain verb 'Armed'")
                    && f.message.contains("At")),
            "{:?}",
            rec.findings
        );
    }

    #[test]
    fn trigger_files_reference_roster_names_for_the_cross_check() {
        let src =
            "When(Unit(\"hub\").IsDestroyed())\n\t.Do(Transfer.Units(\"outpost\", Team.Player))\n";
        let rec = crate::recognizer::recognize_file("triggers/t.lua", src).unwrap();
        let units: Vec<&str> = rec.file.unit_refs.iter().map(|r| r.name.as_str()).collect();
        let groups: Vec<&str> = rec
            .file
            .group_refs
            .iter()
            .map(|r| r.name.as_str())
            .collect();
        assert_eq!(units, vec!["hub"]);
        assert_eq!(groups, vec!["outpost"]);
        assert!(rec.file.unit_defs.is_empty());
    }

    #[test]
    fn mode_presets_recognize_with_their_import_preamble_and_return_chain() {
        let dir = std::env::temp_dir().join(format!("bmk-modes-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("types")).unwrap();
        std::fs::create_dir_all(dir.join("modes")).unwrap();
        std::fs::write(
            dir.join("types/dsl.lua"),
            "---@meta dsl\n\n---@class TestModeChain\n---@field Desc fun(d: string): TestModeChain\n---@field Deny fun(n: table): TestModeChain\n\n---@param name string\n---@return TestModeChain\nfunction Mode(name) end\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("modes/strict.lua"),
            "local ModeDSL = VFS.Include(\"modules/x/mode_dsl.lua\")\nlocal Mode, Share = ModeDSL.Mode, ModeDSL.Share\n\nreturn Mode(\"Strict\")\n\t.Desc(\"No sharing, taxed at -1.\")\n\t.Deny(Share.Resources)\n",
        )
        .unwrap();

        let (ast, findings) = crate::collect_ast(&[dir.clone()], 1);
        assert!(
            findings.is_empty(),
            "{:?}",
            findings.iter().map(|f| &f.message).collect::<Vec<_>>()
        );
        let steps: Vec<&str> = ast.files[0].groups[0].triggers[0]
            .steps
            .iter()
            .map(|s| s.verb.as_str())
            .collect();
        assert_eq!(steps, vec!["Mode", "Desc", "Deny"]);
        match &ast.files[0].groups[0].triggers[0].steps[1].args[0] {
            Value::String { value, .. } => assert!(value.contains("-1")),
            other => panic!("expected desc string, got {other:?}"),
        }
        // locals are real Lua and may bind anything the subset admits; control
        // flow is what stays outside the surface
        std::fs::write(
            dir.join("modes/bad.lua"),
            "local x = \"x\"\nif x then end\nreturn Mode(\"Bad\").Desc(x)\n",
        )
        .unwrap();
        let (ast, findings) = crate::collect_ast(&[dir.clone()], 2);
        assert_eq!(
            findings.len(),
            1,
            "{:?}",
            findings.iter().map(|f| &f.message).collect::<Vec<_>>()
        );
        assert!(findings[0].message.contains("no control flow"));
        let bad = ast
            .files
            .iter()
            .find(|f| f.path.ends_with("bad.lua"))
            .unwrap();
        match &bad.groups[0].triggers[0].steps[1].args[0] {
            Value::String { value, .. } => assert_eq!(value, "x"),
            other => panic!("the bound local reads as its string, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn the_mission_walk_cross_checks_names_against_the_roster() {
        let dir = std::env::temp_dir().join(format!("bmk-crosscheck-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("triggers")).unwrap();
        std::fs::write(
            dir.join("units.lua"),
            "Spawn(UnitDef(\"corlab\"), \"gaia\")\n\t.At(0.4, 0.4)\n\t.Named(\"hub\")\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("triggers/t.lua"),
            "When(Unit(\"hubb\").IsDestroyed())\n\t.Do(Objective(\"x\").Complete())\n",
        )
        .unwrap();
        let (ast, findings) = crate::collect_ast(&[dir.clone()], 1);
        assert!(
            findings
                .iter()
                .any(|f| f.message.contains("no such name") && f.message.contains("hubb")),
            "{:?}",
            findings.iter().map(|f| &f.message).collect::<Vec<_>>()
        );
        assert_eq!(
            ast.surface["enums"]["team_role"][0].as_str(),
            Some("player")
        );
        std::fs::remove_dir_all(&dir).ok();
    }
}
