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
use crate::view;
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
    /// Hash of the file content the edit was computed against (FileAst.hash).
    /// The write is refused if the file changed since — compare-and-swap;
    /// the regeneration loop then refreshes the stale view.
    #[serde(default)]
    pub base_hash: Option<String>,
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
    /// Absolute missions root, so editor clients can map `path:line` findings
    /// in `message` onto real files (VS Code diagnostics).
    missions_dir: String,
}

pub struct Server {
    pub missions_dir: PathBuf,
    pub editor_dir: PathBuf,
    pub editor_cmd: String,
    /// When set, the editor follows the game: active_mission.json (published
    /// by the bridge) re-scopes missions_dir to root/<name>.
    pub missions_root: Option<PathBuf>,
    generation: u64,
    open_seq: u64,
}

impl Server {
    pub fn new(
        missions_dir: PathBuf,
        editor_dir: PathBuf,
        editor_cmd: String,
        missions_root: Option<PathBuf>,
    ) -> Self {
        Server { missions_dir, editor_dir, editor_cmd, missions_root, generation: 0, open_seq: 0 }
    }

    /// Picker click in-game -> loader stamps mission_name -> bridge publishes
    /// active_mission.json -> the whole editor re-scopes (form, probes, Edit
    /// target). Only in --missions-root mode.
    fn follow_active(&mut self) {
        let Some(root) = &self.missions_root else {
            return;
        };
        let Ok(text) = std::fs::read_to_string(self.editor_dir.join("active_mission.json")) else {
            return;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
            return;
        };
        let Some(name) = value.get("name").and_then(|n| n.as_str()) else {
            return;
        };
        if name.is_empty()
            || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            return;
        }
        let candidate = root.join(name);
        if candidate.is_dir() && candidate != self.missions_dir {
            eprintln!("following armed mission: {name}");
            self.missions_dir = candidate;
        }
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

            self.follow_active();
            // domains.json (client-published dropdown data) re-renders too;
            // the dir itself is part of the print so re-scoping regenerates.
            let fingerprint = format!(
                "{}\n{}\n{}",
                self.missions_dir.display(),
                fingerprint_dir(&self.missions_dir),
                file_stamp(&self.editor_dir.join("domains.json"))
            );
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
        self.write_view(&ast);
        let dot = crate::graph::dot(&ast);
        std::fs::write(self.editor_dir.join("mission_graph.dot"), dot).ok();
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

    fn write_view(&self, ast: &MissionAst) {
        let domains: view::Domains = std::fs::read_to_string(self.editor_dir.join("domains.json"))
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        let artifact = view::render(ast, &domains);
        let json = serde_json::to_string(&artifact).expect("serializable view");
        let path = self.editor_dir.join("mission_view.json");
        if let Err(e) = std::fs::write(&path, json) {
            eprintln!("cannot write {}: {e}", path.display());
        }
    }

    fn write_status(&self, ok: bool, message: &str) {
        let missions_dir = self
            .missions_dir
            .canonicalize()
            .unwrap_or_else(|_| self.missions_dir.clone())
            .display()
            .to_string();
        let status = Status { generation: self.generation, ok, message: message.to_string(), missions_dir };
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

    /// Open requests become a sequenced open-target artifact (GET
    /// /open_request): every VS Code window's extension polls it, and the one
    /// whose workspace contains the file acts. A non-empty --editor-cmd
    /// additionally shells out, for extension-less setups.
    fn consume_open_request(&mut self) {
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
        let file = file.canonicalize().unwrap_or(file);
        self.open_seq += 1;
        let target = serde_json::json!({
            "seq": self.open_seq,
            "file": file.display().to_string(),
            "line": request.line,
        });
        std::fs::write(self.editor_dir.join("open_target.json"), target.to_string()).ok();
        eprintln!("open target [{}]: {}:{}", self.open_seq, file.display(), request.line);
        if !self.editor_cmd.is_empty() {
            let cmd = self
                .editor_cmd
                .replace("{file}", &file.display().to_string())
                .replace("{line}", &request.line.to_string());
            eprintln!("opening: {cmd}");
            let _ = std::process::Command::new("sh").arg("-c").arg(&cmd).spawn();
        }
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
    if let Some(base_hash) = &intent.base_hash {
        let current = recognizer::fnv1a(source.as_bytes());
        if &current != base_hash {
            return Err(format!(
                "file changed on disk since the view was built ({}) — refreshing view instead of writing",
                intent.file
            ));
        }
    }
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

fn file_stamp(path: &Path) -> String {
    let meta = std::fs::metadata(path).ok();
    let mtime = meta
        .as_ref()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let size = meta.map(|m| m.len()).unwrap_or(0);
    format!("{}|{mtime}|{size}", path.display())
}

/// Cheap change detection: every .lua path + mtime + size, concatenated.
fn fingerprint_dir(dir: &Path) -> String {
    let mut entries: Vec<String> = Vec::new();
    let pattern = format!("{}/**/triggers/*.lua", dir.display());
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
            "When(Team.Player.Has(UnitDef(\"armpw\"), 3))\n\t.Do(Objective(\"x\").Complete())\n",
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
            base_hash: Some(crate::recognizer::fnv1a(source.as_bytes())),
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
            base_hash: None,
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
            base_hash: None,
        };
        assert!(apply_edit(&dir, &intent).is_err());
    }

    #[test]
    fn a_stale_base_hash_is_refused_without_writing() {
        let dir = tmpdir("cas");
        setup(&dir);
        let source = std::fs::read_to_string(dir.join("hello/triggers/win.lua")).unwrap();
        let at = source.find(", 3)").unwrap() + 2;
        let intent = EditIntent {
            file: "hello/triggers/win.lua".into(),
            start: at,
            end: at + 1,
            new_text: "5".into(),
            base_hash: Some("0000000000000000".into()),
        };
        let err = apply_edit(&dir, &intent).unwrap_err();
        assert!(err.contains("changed on disk"), "{err}");
        let after = std::fs::read_to_string(dir.join("hello/triggers/win.lua")).unwrap();
        assert_eq!(source, after);
    }

    #[test]
    fn an_appended_trigger_chain_passes_the_gate() {
        let dir = tmpdir("append");
        setup(&dir);
        let source = std::fs::read_to_string(dir.join("hello/triggers/win.lua")).unwrap();
        let at = source.len();
        let intent = EditIntent {
            file: "hello/triggers/win.lua".into(),
            start: at,
            end: at,
            new_text: "\nWhen(Objective(\"x\").IsComplete())\n\t.Do(Objective(\"y\").Complete())\n".into(),
            base_hash: Some(crate::recognizer::fnv1a(source.as_bytes())),
        };
        apply_edit(&dir, &intent).unwrap();
        let edited = std::fs::read_to_string(dir.join("hello/triggers/win.lua")).unwrap();
        let rec = crate::recognizer::recognize_file("t.lua", &edited).unwrap();
        assert!(rec.findings.is_empty());
        assert_eq!(rec.file.groups[0].triggers.len(), 2);
    }

    #[test]
    fn open_requests_become_routable_targets() {
        let dir = tmpdir("open");
        setup(&dir);
        let editor = tmpdir("open-editor");
        let mut server = Server::new(dir.clone(), editor.clone(), String::new(), None);
        std::fs::write(
            editor.join("open_request.json"),
            "{\"file\":\"hello/triggers/win.lua\",\"line\":2}",
        )
        .unwrap();
        server.consume_open_request();
        let target: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(editor.join("open_target.json")).unwrap())
                .unwrap();
        assert_eq!(target["seq"], 1);
        assert_eq!(target["line"], 2);
        assert!(target["file"].as_str().unwrap().ends_with("hello/triggers/win.lua"));
        assert!(target["file"].as_str().unwrap().starts_with('/'), "absolute path for window routing");
        assert!(!editor.join("open_request.json").exists());
    }

    #[test]
    fn the_editor_follows_the_armed_mission() {
        let root = tmpdir("follow-root");
        std::fs::create_dir_all(root.join("alpha/triggers")).unwrap();
        std::fs::create_dir_all(root.join("beta/triggers")).unwrap();
        let editor = tmpdir("follow-editor");
        let mut server = Server::new(root.clone(), editor.clone(), String::new(), Some(root.clone()));

        std::fs::write(editor.join("active_mission.json"), "{\"name\":\"beta\"}").unwrap();
        server.follow_active();
        assert_eq!(server.missions_dir, root.join("beta"));

        // path-shaped names are refused; scope stays where it was
        std::fs::write(editor.join("active_mission.json"), "{\"name\":\"../../etc\"}").unwrap();
        server.follow_active();
        assert_eq!(server.missions_dir, root.join("beta"));

        // without --missions-root nothing moves
        let mut pinned = Server::new(root.join("alpha"), editor.clone(), String::new(), None);
        std::fs::write(editor.join("active_mission.json"), "{\"name\":\"beta\"}").unwrap();
        pinned.follow_active();
        assert_eq!(pinned.missions_dir, root.join("alpha"));
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
            base_hash: None,
        };
        assert!(apply_edit(&dir, &intent).is_err());
    }
}
