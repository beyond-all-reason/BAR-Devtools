//! bar-mission-kit: the mission DSL recognizer + validator CLI.
//!
//! One grammar, two consumers:
//!   parse  — emit the decorated mission AST as JSON (the RML form's input,
//!            and later the write-back layer's document model)
//!   check  — same walk, findings only; nonzero exit on a non-conforming
//!            mission (CI's validator)

mod model;
mod recognizer;

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
}

fn collect_lua_files(paths: &[PathBuf]) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for path in paths {
        if path.is_dir() {
            let pattern = format!("{}/**/*.lua", path.display());
            for entry in glob::glob(&pattern).expect("valid glob").flatten() {
                files.push(entry);
            }
        } else {
            files.push(path.clone());
        }
    }
    files.sort();
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

fn run(paths: &[PathBuf]) -> (model::MissionAst, Vec<model::Finding>) {
    let files = collect_lua_files(paths);
    let mut ast = model::MissionAst { version: 1, files: Vec::new() };
    let mut findings = Vec::new();
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
        match recognizer::recognize_file(&rel, &source) {
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
    (ast, findings)
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.command {
        Command::Parse { paths, out } => {
            let (ast, findings) = run(&paths);
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
            let (_ast, findings) = run(&paths);
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
    }
}

#[cfg(test)]
mod tests {
    use crate::model::Value;

    const WIN: &str = r#"
T.When(Team.Player.Has(UnitDef("armpw"), 3))
	.Do(Objective("build_pawns").Complete())
	.Register()

T.When(Objective("build_pawns").IsComplete())
	.Do(MatchFlow.Victory(Team.Player))
	.Register()
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
        assert_eq!(steps, vec!["When", "Do", "Register"]);

        // When's condition: Team.Player.Has(UnitDef("armpw"), 3)
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

        // Do's effect: MatchFlow.Victory(Team.Player) in trigger 2
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
T.When(Region("north").EnteredBy(Team.Player, { count = 5 }))
	.Do(Wave.Define("flank").Route(Path("east")).Spawn())
	.Register()
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
        let src = "T.When(C()).Do(function() end).Register()\n";
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
T.When(C()).Do(E()).Register()
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
    fn missing_register_is_a_finding() {
        let src = "T.When(C()).Do(E())\n";
        let rec = crate::recognizer::recognize_file("triggers/r.lua", src).unwrap();
        assert!(rec.findings.iter().any(|f| f.message.contains("Register")));
    }
}
