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
    Check {
        paths: Vec<PathBuf>,
    },
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
                format!("{}/**/modes/*.lua", path.display()),
            ] {
                for entry in glob::glob(&pattern).expect("valid glob").flatten() {
                    // spec/modes/, spec/**/triggers/ etc. are busted's, not ours.
                    if entry.components().any(|c| c.as_os_str() == "spec") {
                        continue;
                    }
                    // modules/modes is a MODULE (mode infrastructure); its own
                    // files aren't presets. Presets live in <module>/modes/.
                    fn dir_name(p: Option<&std::path::Path>) -> &str {
                        p.and_then(|d| d.file_name()).and_then(|n| n.to_str()).unwrap_or("")
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

pub(crate) const MISSION_SURFACE: &str = include_str!("../surfaces/missions.json");

pub fn collect_ast(paths: &[PathBuf], generation: u64) -> (model::MissionAst, Vec<model::Finding>) {
    let files = collect_lua_files(paths);
    // The grammar's source of truth: the game's LuaCATS types. Resolution is
    // PER FILE — each file answers to its own module's published surface
    // (nearest marked types/ dir), so a sharing mode preset and a mission
    // trigger file check against different vocabularies in one walk.
    let mut surfaces: std::collections::HashMap<PathBuf, std::rc::Rc<types::TypeSurface>> =
        std::collections::HashMap::new();
    let mut surface_for = |file: &PathBuf| -> std::rc::Rc<types::TypeSurface> {
        let key = types::TypeSurface::types_dir_near(file)
            .unwrap_or_else(|| PathBuf::from("<builtin>"));
        surfaces
            .entry(key)
            .or_insert_with(|| std::rc::Rc::new(types::TypeSurface::load_near(std::slice::from_ref(file))))
            .clone()
    };

    let mut surface: serde_json::Value =
        serde_json::from_str(MISSION_SURFACE).expect("valid surface overlay");
    let mut ast = model::MissionAst { version: 1, generation, files: Vec::new(), surface: serde_json::Value::Null };
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
            }),
        }
    }
    if let Some(overlay) = surface.as_object_mut() {
        // Derived editor enums ride the artifact so every terminal renders
        // literal-union parameters as pickers.
        overlay.insert("enums".into(), serde_json::to_value(enums).expect("serializable enums"));
    }
    ast.surface = surface;
    findings.extend(cross_check_names(&ast.files));
    (ast, findings)
}

/// Cross-file noun check: every Unit()/Units reference must name something
/// units.lua declared. Only meaningful when a roster was walked — a partial
/// (single-file) invocation stays quiet.
fn cross_check_names(files: &[model::FileAst]) -> Vec<model::Finding> {
    if !files.iter().any(|f| f.path.ends_with("units.lua")) {
        return Vec::new();
    }
    let unit_defs: std::collections::HashSet<&str> =
        files.iter().flat_map(|f| f.unit_defs.iter().map(String::as_str)).collect();
    let group_defs: std::collections::HashSet<&str> =
        files.iter().flat_map(|f| f.group_defs.iter().map(String::as_str)).collect();
    let mut findings = Vec::new();
    for file in files {
        for r in &file.unit_refs {
            if !unit_defs.contains(r.name.as_str()) {
                findings.push(model::Finding {
                    path: file.path.clone(),
                    line: r.line,
                    message: format!("Unit(\"{}\"): units.lua declares no such name", r.name),
                });
            }
        }
        for r in &file.group_refs {
            if !group_defs.contains(r.name.as_str()) {
                findings.push(model::Finding {
                    path: file.path.clone(),
                    line: r.line,
                    message: format!("group \"{}\": units.lua declares no such group", r.name),
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
        Command::Serve { missions_dir, missions_root, editor_dir, editor_cmd, listen } => {
            let Some(initial) = missions_dir.or_else(|| missions_root.clone()) else {
                eprintln!("serve needs a missions dir or --missions-root");
                return ExitCode::FAILURE;
            };
            http::spawn(&listen, editor_dir.clone());
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
                let names: Vec<Option<&str>> =
                    calls.iter().map(|c| c.name.as_deref()).collect();
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
        let src = "local x = 1\n";
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
        assert!(WIN[..at].trim_end().ends_with(".Do(Objective(\"build_pawns\").Complete())"), "{}", &WIN[..at]);
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
        assert!(rec.findings.iter().any(|f| f.message.contains("Register is gone")));
    }

    #[test]
    fn an_undeclared_statement_verb_is_a_finding() {
        let src = "Spwan(UnitDef(\"corlab\"), \"gaia\").At(0.1, 0.1)\n";
        let rec = crate::recognizer::recognize_file("units.lua", src).unwrap();
        assert!(rec.findings.iter().any(|f| f.message.contains("unknown statement verb 'Spwan'")
            && f.message.contains("When")
            && f.message.contains("Spawn")), "{:?}", rec.findings);
        assert_eq!(rec.file.opaque.len(), 1);
    }

    #[test]
    fn spawn_chains_are_recognized_from_the_types() {
        let src = "Spawn(UnitDef(\"corlab\"), \"gaia\")\n\t.At(0.42, 0.42)\n\t.Named(\"hub\")\n\t.Grouped(\"outpost\")\n";
        let rec = crate::recognizer::recognize_file("units.lua", src).unwrap();
        assert!(rec.findings.is_empty(), "findings: {:?}", rec.findings);
        let steps: Vec<&str> = rec.file.groups[0].triggers[0].steps.iter().map(|s| s.verb.as_str()).collect();
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
        assert!(rec.findings.iter().any(|f| f.message.contains("no At")), "{:?}", rec.findings);
        assert!(rec.findings.iter().any(|f| f.message.contains("unknown chain verb 'Armed'")
            && f.message.contains("At")), "{:?}", rec.findings);
    }

    #[test]
    fn trigger_files_reference_roster_names_for_the_cross_check() {
        let src = "When(Unit(\"hub\").IsDestroyed())\n\t.Do(Units.Transfer(\"outpost\", Team.Player))\n";
        let rec = crate::recognizer::recognize_file("triggers/t.lua", src).unwrap();
        let units: Vec<&str> = rec.file.unit_refs.iter().map(|r| r.name.as_str()).collect();
        let groups: Vec<&str> = rec.file.group_refs.iter().map(|r| r.name.as_str()).collect();
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
        assert!(findings.is_empty(), "{:?}", findings.iter().map(|f| &f.message).collect::<Vec<_>>());
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
        // a real (non-import) local is still outside the surface
        std::fs::write(
            dir.join("modes/bad.lua"),
            "local x = 1\nreturn Mode(\"Bad\").Desc(\"x\")\n",
        )
        .unwrap();
        let (_ast, findings) = crate::collect_ast(&[dir.clone()], 2);
        assert!(findings.iter().any(|f| f.message.contains("import")), "{:?}",
            findings.iter().map(|f| &f.message).collect::<Vec<_>>());
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
        assert!(findings.iter().any(|f| f.message.contains("no such name") && f.message.contains("hubb")),
            "{:?}", findings.iter().map(|f| &f.message).collect::<Vec<_>>());
        assert_eq!(
            ast.surface["enums"]["team_role"][0].as_str(),
            Some("player")
        );
        std::fs::remove_dir_all(&dir).ok();
    }
}
