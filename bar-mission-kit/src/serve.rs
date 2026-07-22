//! Serve mode: the long-running editor service. The filesystem is the entire
//! interface (editor_architecture_plan.md):
//!
//!   missions/**.lua  --watch-->  <editor-dir>/mission_ast.json   (file -> UI)
//!   <editor-dir>/edits/*.json  --apply+validate-->  missions/**.lua  (UI -> file)
//!   <editor-dir>/open_request.json  -->  $EDITOR_CMD (mode switch to code)
//!
//! Every write to a mission file goes through the recognizer first: an edit
//! that produces a parse error or a grammar finding is rejected and reported
//! in <editor-dir>/status.json. The .lua file stays the source of truth.

use crate::model::MissionAst;
use crate::recognizer;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

const POLL: Duration = Duration::from_millis(300);

/// A span edit the UI (or any tool) requests: replace bytes [start, end) of
/// `file` (mission-relative path, as emitted in the AST) with `new_text`.
#[derive(Deserialize, Debug)]
pub struct EditIntent {
    pub file: String,
    pub start: usize,
    pub end: usize,
    pub new_text: String,
}

#[derive(Deserialize, Debug)]
pub struct OpenRequest {
    pub file: String,
    #[serde(default = "one")]
    pub line: usize,
}

fn one() -> usize {
    1
}

#[derive(Serialize, Default)]
struct Status {
    generation: u64,
    ok: bool,
    message: String,
}

pub struct Server {
    pub missions_dir: PathBuf,
    pub editor_dir: PathBuf,
    pub editor_cmd: String,
    generation: u64,
}

impl Server {
    pub fn new(missions_dir: PathBuf, editor_dir: PathBuf, editor_cmd: String) -> Self {
        Server { missions_dir, editor_dir, editor_cmd, generation: 0 }
    }

    pub fn run(&mut self) -> ! {
        std::fs::create_dir_all(self.editor_dir.join("edits")).ok();
        let mut last_fingerprint = String::new();
        eprintln!(
            "bar-mission-kit serve: {} -> {} (editor: {})",
            self.missions_dir.display(),
            self.editor_dir.display(),
            self.editor_cmd
        );
        loop {
            // UI -> file first, so a just-applied edit regenerates in the
            // same tick.
            self.consume_edits();
            self.consume_open_request();

            let fingerprint = fingerprint_dir(&self.missions_dir);
            if fingerprint != last_fingerprint {
                last_fingerprint = fingerprint;
                self.regenerate();
            }
            std::thread::sleep(POLL);
        }
    }

    fn regenerate(&mut self) {
        self.generation += 1;
        let (ast, findings) = crate::collect_ast(&[self.missions_dir.clone()], self.generation);
        let message = findings
            .iter()
            .map(|f| format!("{}:{}: {}", f.path, f.line, f.message))
            .collect::<Vec<_>>()
            .join("\n");
        self.write_ast(&ast);
        self.write_status(findings.is_empty(), &message);
        if findings.is_empty() {
            eprintln!("[gen {}] AST regenerated", self.generation);
        } else {
            eprintln!("[gen {}] AST regenerated with findings:\n{message}", self.generation);
        }
    }

    fn write_ast(&self, ast: &MissionAst) {
        let json = serde_json::to_string_pretty(ast).expect("serializable AST");
        let path = self.editor_dir.join("mission_ast.json");
        if let Err(e) = std::fs::write(&path, json) {
            eprintln!("cannot write {}: {e}", path.display());
        }
    }

    fn write_status(&self, ok: bool, message: &str) {
        let status = Status { generation: self.generation, ok, message: message.to_string() };
        let json = serde_json::to_string_pretty(&status).expect("serializable status");
        std::fs::write(self.editor_dir.join("status.json"), json).ok();
    }

    fn consume_edits(&mut self) {
        let edits_dir = self.editor_dir.join("edits");
        let Ok(entries) = std::fs::read_dir(&edits_dir) else {
            return;
        };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().map(|x| x == "json").unwrap_or(false))
            .collect();
        paths.sort();
        for path in paths {
            let outcome = self.apply_edit_file(&path);
            if let Err(message) = outcome {
                eprintln!("edit rejected: {message}");
                self.generation += 1;
                self.write_status(false, &message);
            }
            std::fs::remove_file(&path).ok();
        }
    }

    fn apply_edit_file(&mut self, path: &Path) -> Result<(), String> {
        let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
        let intent: EditIntent =
            serde_json::from_str(&text).map_err(|e| format!("bad edit intent: {e}"))?;
        apply_edit(&self.missions_dir, &intent)?;
        eprintln!("applied edit to {} [{}..{})", intent.file, intent.start, intent.end);
        Ok(())
    }

    fn consume_open_request(&self) {
        let path = self.editor_dir.join("open_request.json");
        let Ok(text) = std::fs::read_to_string(&path) else {
            return;
        };
        std::fs::remove_file(&path).ok();
        let request: OpenRequest = match serde_json::from_str(&text) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("bad open request: {e}");
                return;
            }
        };
        let Ok(file) = resolve_mission_file(&self.missions_dir, &request.file) else {
            eprintln!("open request outside missions dir: {}", request.file);
            return;
        };
        let cmd = self
            .editor_cmd
            .replace("{file}", &file.display().to_string())
            .replace("{line}", &request.line.to_string());
        eprintln!("opening: {cmd}");
        let _ = std::process::Command::new("sh").arg("-c").arg(&cmd).spawn();
    }
}

/// Resolve a mission-relative path defensively (no escaping the tree).
fn resolve_mission_file(missions_dir: &Path, rel: &str) -> Result<PathBuf, String> {
    if rel.contains("..") || rel.starts_with('/') {
        return Err(format!("suspicious path: {rel}"));
    }
    let path = missions_dir.join(rel);
    if !path.is_file() {
        return Err(format!("no such mission file: {rel}"));
    }
    Ok(path)
}

/// Apply a span edit to a mission file — but only if the result still
/// parses AND passes the recognizer with zero findings. The grammar is the
/// write gate; a rejected edit changes nothing on disk.
pub fn apply_edit(missions_dir: &Path, intent: &EditIntent) -> Result<(), String> {
    let path = resolve_mission_file(missions_dir, &intent.file)?;
    let source = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    if intent.start > intent.end || intent.end > source.len() {
        return Err(format!(
            "edit span [{}, {}) out of bounds for {} ({} bytes)",
            intent.start,
            intent.end,
            intent.file,
            source.len()
        ));
    }
    let mut edited = String::with_capacity(source.len() + intent.new_text.len());
    edited.push_str(&source[..intent.start]);
    edited.push_str(&intent.new_text);
    edited.push_str(&source[intent.end..]);

    let recognized = recognizer::recognize_file(&intent.file, &edited)
        .map_err(|e| format!("edit rejected — result does not parse: {e}"))?;
    if !recognized.findings.is_empty() {
        let msgs = recognized
            .findings
            .iter()
            .map(|f| f.message.clone())
            .collect::<Vec<_>>()
            .join("; ");
        return Err(format!("edit rejected — result leaves the mission subset: {msgs}"));
    }

    std::fs::write(&path, edited).map_err(|e| e.to_string())
}

/// Cheap change detection: every .lua path + mtime + size, concatenated.
fn fingerprint_dir(dir: &Path) -> String {
    let mut entries: Vec<String> = Vec::new();
    let pattern = format!("{}/**/*.lua", dir.display());
    for path in glob::glob(&pattern).into_iter().flatten().flatten() {
        let meta = std::fs::metadata(&path).ok();
        let mtime = meta
            .as_ref()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let size = meta.map(|m| m.len()).unwrap_or(0);
        entries.push(format!("{}|{mtime}|{size}", path.display()));
    }
    entries.sort();
    entries.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup(dir: &Path) {
        std::fs::create_dir_all(dir.join("hello/triggers")).unwrap();
        std::fs::write(
            dir.join("hello/triggers/win.lua"),
            "T.When(Team.Player.Has(UnitDef(\"armpw\"), 3))\n\t.Do(Objective(\"x\").Complete())\n\t.Register()\n",
        )
        .unwrap();
    }

    fn tmpdir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("bar-mission-kit-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_valid_span_edit_applies() {
        let dir = tmpdir("valid");
        setup(&dir);
        let source = std::fs::read_to_string(dir.join("hello/triggers/win.lua")).unwrap();
        let at = source.find(", 3)").unwrap() + 2;
        let intent = EditIntent {
            file: "hello/triggers/win.lua".into(),
            start: at,
            end: at + 1,
            new_text: "5".into(),
        };
        apply_edit(&dir, &intent).unwrap();
        let edited = std::fs::read_to_string(dir.join("hello/triggers/win.lua")).unwrap();
        assert!(edited.contains(", 5)"));
    }

    #[test]
    fn an_edit_that_breaks_the_grammar_is_rejected_and_leaves_the_file_alone() {
        let dir = tmpdir("grammar");
        setup(&dir);
        let source = std::fs::read_to_string(dir.join("hello/triggers/win.lua")).unwrap();
        let at = source.find(", 3)").unwrap() + 2;
        let intent = EditIntent {
            file: "hello/triggers/win.lua".into(),
            start: at,
            end: at + 1,
            new_text: "function() end".into(),
        };
        let err = apply_edit(&dir, &intent).unwrap_err();
        assert!(err.contains("closure-free"), "{err}");
        let after = std::fs::read_to_string(dir.join("hello/triggers/win.lua")).unwrap();
        assert_eq!(source, after);
    }

    #[test]
    fn an_edit_that_breaks_the_parse_is_rejected() {
        let dir = tmpdir("parse");
        setup(&dir);
        let intent = EditIntent {
            file: "hello/triggers/win.lua".into(),
            start: 0,
            end: 1,
            new_text: ")(".into(),
        };
        assert!(apply_edit(&dir, &intent).is_err());
    }

    #[test]
    fn paths_cannot_escape_the_missions_dir() {
        let dir = tmpdir("escape");
        setup(&dir);
        let intent = EditIntent {
            file: "../../etc/passwd".into(),
            start: 0,
            end: 0,
            new_text: "x".into(),
        };
        assert!(apply_edit(&dir, &intent).is_err());
    }
}
