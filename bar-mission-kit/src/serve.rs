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

use crate::model::{MissionAst, Span};
use crate::recognizer;
use crate::view;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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
    /// A whole-file hash, so a second edit from the same view generation
    /// always arrives stale; the journal rebases it onto the current file, and
    /// only a genuine overlap is refused.
    #[serde(default)]
    pub base_hash: Option<String>,
}

/// One write serve performed, keyed by the file hashes it moved between.
#[derive(Clone, Debug)]
struct AppliedEdit {
    before: String,
    after: String,
    start: usize,
    end: usize,
    new_len: usize,
}

/// Recent writes per file, so an intent stamped with an older view generation
/// can be replayed onto what those writes left behind. Only writes serve made
/// itself are recorded: any other route to the current bytes stays a refusal.
#[derive(Default)]
pub struct EditJournal {
    by_file: std::collections::HashMap<String, std::collections::VecDeque<AppliedEdit>>,
}

const JOURNAL_DEPTH: usize = 64;

fn stale(file: &str) -> String {
    format!("file changed on disk since the view was built ({file}) — refreshing view instead of writing")
}

impl EditJournal {
    fn record(&mut self, file: &str, applied: AppliedEdit) {
        let entries = self.by_file.entry(file.to_string()).or_default();
        entries.push_back(applied);
        while entries.len() > JOURNAL_DEPTH {
            entries.pop_front();
        }
    }

    /// Carry `span` from the file state `base` forward to `current`, one
    /// recorded write at a time. Err when the route is unrecorded (someone
    /// else wrote the file) or when a write landed on the span itself.
    fn rebase(&self, file: &str, base: &str, current: &str, span: Span) -> Result<Span, String> {
        let entries = self.by_file.get(file).ok_or_else(|| stale(file))?;
        let (mut start, mut end) = span;
        let mut at = base;
        for _ in 0..=entries.len() {
            if at == current {
                return Ok((start, end));
            }
            // newest first: a file that returned to an earlier state has two
            // edges out of it, and the recent one is the live history
            let step = entries.iter().rev().find(|e| e.before == at).ok_or_else(|| stale(file))?;
            if step.start == start && step.end == end {
                // The same leaf, rewritten: this intent replaces all of it, so
                // it redirects onto the new extent and the later write wins.
                end = start + step.new_len;
            } else if step.start < end && start < step.end {
                return Err(format!(
                    "edit overlaps a newer edit to the same region of {file} — refreshing view instead of writing"
                ));
            } else if step.end <= start {
                let delta = step.new_len as i64 - (step.end - step.start) as i64;
                start = (start as i64 + delta) as usize;
                end = (end as i64 + delta) as usize;
            }
            at = &step.after;
        }
        Err(stale(file))
    }
}

#[derive(Deserialize, Debug)]
pub struct OpenRequest {
    pub file: String,
    #[serde(default = "one")]
    pub line: usize,
}

/// A crumb click: re-scope serve to root/<name>. Same channel discipline as
/// every other intent — a json file in the editor dir, consumed by the loop.
#[derive(Deserialize, Debug)]
pub struct SelectMission {
    pub name: String,
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
    /// Last-seen active_mission.json content: arming is an EVENT, so the
    /// editor follows a change, not the standing file — a manual crumb
    /// selection must not be overridden by a stale arming from last session.
    last_active: String,
    journal: EditJournal,
}

impl Server {
    pub fn new(
        missions_dir: PathBuf,
        editor_dir: PathBuf,
        editor_cmd: String,
        missions_root: Option<PathBuf>,
    ) -> Self {
        Server {
            missions_dir,
            editor_dir,
            editor_cmd,
            missions_root,
            generation: 0,
            open_seq: 0,
            last_active: String::new(),
            journal: EditJournal::default(),
        }
    }

    /// Picker click in-game -> loader stamps mission_name -> bridge publishes
    /// active_mission.json -> the whole editor re-scopes (form, probes, Edit
    /// target). Only in --missions-root mode, and only when the file CHANGES.
    fn follow_active(&mut self) {
        let Some(root) = &self.missions_root else {
            return;
        };
        let Ok(text) = std::fs::read_to_string(self.editor_dir.join("active_mission.json")) else {
            return;
        };
        if text == self.last_active {
            return;
        }
        self.last_active = text.clone();
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
            return;
        };
        let Some(name) = value.get("name").and_then(|n| n.as_str()) else {
            return;
        };
        if !valid_mission_name(name) {
            return;
        }
        let candidate = root.join(name);
        if candidate.is_dir() && candidate != self.missions_dir {
            eprintln!("following armed mission: {name}");
            self.missions_dir = candidate;
        }
    }

    /// Crumb click in any terminal -> select_mission.json -> re-scope. The
    /// game keeps precedence through follow_active: a new arming event is a
    /// change and wins the tick.
    fn consume_select_mission(&mut self) {
        let path = self.editor_dir.join("select_mission.json");
        let Ok(text) = std::fs::read_to_string(&path) else {
            return;
        };
        std::fs::remove_file(&path).ok();
        let Some(root) = &self.missions_root else {
            eprintln!("select_mission ignored: serve is pinned (no --missions-root)");
            return;
        };
        let request: SelectMission = match serde_json::from_str(&text) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("bad select_mission: {e}");
                return;
            }
        };
        if !valid_mission_name(&request.name) {
            eprintln!("select_mission refused: {}", request.name);
            return;
        }
        let candidate = root.join(&request.name);
        if candidate.is_dir() && candidate != self.missions_dir {
            eprintln!("selected mission: {}", request.name);
            self.missions_dir = candidate;
        }
    }

    /// Sibling missions under the root: a mission is a dir with at least one
    /// trigger file. Name charset doubles as the markup-safety guarantee for
    /// the crumb (view embeds names verbatim).
    fn list_missions(&self) -> Vec<String> {
        let Some(root) = &self.missions_root else {
            return Vec::new();
        };
        let mut names: Vec<String> = std::fs::read_dir(root)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().is_dir())
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|name| valid_mission_name(name))
            .filter(|name| {
                let pattern = format!("{}/**/triggers/*.lua", root.join(name).display());
                glob::glob(&pattern).map(|mut g| g.next().is_some()).unwrap_or(false)
            })
            .collect();
        names.sort();
        names
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

            self.consume_select_mission();
            self.follow_active();
            // domains.json (client-published dropdown data) re-renders too;
            // the dir itself is part of the print so re-scoping regenerates,
            // and the sibling list so a new mission dir appears in the crumb.
            let fingerprint = format!(
                "{}\n{}\n{}\n{}",
                self.missions_dir.display(),
                fingerprint_dir(&self.missions_dir),
                file_stamp(&self.editor_dir.join("domains.json")),
                self.list_missions().join(",")
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
        let scope = view::Scope {
            mission: self
                .missions_dir
                .file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.to_string()),
            missions: self.list_missions(),
        };
        let artifact = view::render(ast, &domains, &scope);
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
        paths.sort_by_key(|p| natural_key(p));
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
        let span = apply_edit_journaled(&self.missions_dir, &intent, &mut self.journal)?;
        eprintln!("applied edit to {} [{}..{})", intent.file, span.0, span.1);
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
        // `ts` lets a freshly started terminal tell a live request from a
        // stale artifact: seq alone cannot, since it restarts with serve.
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let target = serde_json::json!({
            "seq": self.open_seq,
            "ts": ts,
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

#[derive(PartialEq, Eq, PartialOrd, Ord)]
enum Chunk {
    Text(String),
    Number(u128),
}

/// Intent filenames carry numbers (`<frame>_<seq>.json`, `http_<ms>_<n>.json`)
/// and do not sort lexicographically in submission order: "1000_2" < "900_1".
/// Compare digit runs numerically so the drain order is the write order.
fn natural_key(path: &Path) -> Vec<Chunk> {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mut chunks = Vec::new();
    let mut rest = name.as_str();
    while !rest.is_empty() {
        let digit = rest.starts_with(|c: char| c.is_ascii_digit());
        let split = rest.find(|c: char| c.is_ascii_digit() != digit).unwrap_or(rest.len());
        let (head, tail) = rest.split_at(split);
        chunks.push(if digit {
            head.parse().map(Chunk::Number).unwrap_or_else(|_| Chunk::Text(head.into()))
        } else {
            Chunk::Text(head.into())
        });
        rest = tail;
    }
    chunks
}

fn valid_mission_name(name: &str) -> bool {
    !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
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

/// Inserted text adopts the document's line endings: the UI's templates are
/// LF, and mission files are frequently CRLF — an LF insertion would seed a
/// mixed document and, at EOF, rewrite the file's terminal bytes. A document
/// with no clear convention is left to speak for itself.
fn match_line_endings(source: &str, new_text: &str) -> String {
    let crlf = source.matches("\r\n").count();
    let lf = source.matches('\n').count() - crlf;
    if crlf > lf {
        new_text.replace("\r\n", "\n").replace('\n', "\r\n")
    } else if crlf == 0 {
        new_text.replace("\r\n", "\n")
    } else {
        new_text.to_string()
    }
}

/// Apply a span edit to a mission file — but only if the result still
/// parses AND passes the recognizer with zero findings. The grammar is the
/// write gate; a rejected edit changes nothing on disk. An intent stamped
/// with an earlier view generation rebases onto serve's own intervening
/// writes through `journal`. Returns the span actually written.
pub fn apply_edit_journaled(
    missions_dir: &Path,
    intent: &EditIntent,
    journal: &mut EditJournal,
) -> Result<Span, String> {
    let path = resolve_mission_file(missions_dir, &intent.file)?;
    let source = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let current = recognizer::fnv1a(source.as_bytes());
    let (start, end) = match &intent.base_hash {
        Some(base) if base != &current => {
            journal.rebase(&intent.file, base, &current, (intent.start, intent.end))?
        }
        _ => (intent.start, intent.end),
    };
    if start > end || end > source.len() {
        return Err(format!(
            "edit span [{}, {}) out of bounds for {} ({} bytes)",
            start,
            end,
            intent.file,
            source.len()
        ));
    }
    let new_text = match_line_endings(&source, &intent.new_text);
    let mut edited = String::with_capacity(source.len() + new_text.len());
    edited.push_str(&source[..start]);
    edited.push_str(&new_text);
    edited.push_str(&source[end..]);

    // Gate against the same type-derived grammar the view was built from.
    let surface = crate::types::TypeSurface::load_near(&[missions_dir.to_path_buf()]);
    let recognized = recognizer::recognize_file_with(&intent.file, &edited, &surface)
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

    let after = recognizer::fnv1a(edited.as_bytes());
    std::fs::write(&path, edited).map_err(|e| e.to_string())?;
    journal.record(
        &intent.file,
        AppliedEdit { before: current, after, start, end, new_len: new_text.len() },
    );
    Ok((start, end))
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
    let mut paths: Vec<PathBuf> = Vec::new();
    for pattern in [
        format!("{}/**/triggers/*.lua", dir.display()),
        format!("{}/**/units.lua", dir.display()),
    ] {
        for path in glob::glob(&pattern).into_iter().flatten().flatten() {
            paths.push(path);
        }
    }
    let roster = dir.join("units.lua");
    if roster.is_file() {
        paths.push(roster);
    }
    paths.sort();
    paths.dedup();
    for path in paths {
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

    fn apply_edit(missions_dir: &Path, intent: &EditIntent) -> Result<(), String> {
        apply_edit_journaled(missions_dir, intent, &mut EditJournal::default()).map(|_| ())
    }

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

    const WIN: &str =
        "When(Team.Player.Has(UnitDef(\"armpw\"), 3))\n\t.Do(Objective(\"x\").Complete())\n";

    /// The documents the editor actually meets: BAR working trees are CRLF in
    /// places, and not every file ends with a terminator.
    fn documents() -> Vec<(&'static str, String)> {
        let crlf = WIN.replace('\n', "\r\n");
        vec![
            ("lf", WIN.to_string()),
            ("crlf", crlf.clone()),
            ("crlf-no-final-newline", crlf.trim_end_matches("\r\n").to_string()),
            ("lf-no-final-newline", WIN.trim_end_matches('\n').to_string()),
        ]
    }

    fn seed(dir: &Path, source: &str) {
        std::fs::create_dir_all(dir.join("hello/triggers")).unwrap();
        std::fs::write(dir.join("hello/triggers/win.lua"), source).unwrap();
    }

    fn edited_text(dir: &Path) -> String {
        std::fs::read_to_string(dir.join("hello/triggers/win.lua")).unwrap()
    }

    /// A write is the exact splice: every byte outside [start, end) survives,
    /// terminal bytes included, and inserted lines keep the document's
    /// line-ending convention instead of the template's.
    #[test]
    fn a_write_touches_only_the_span_it_edits() {
        for (name, source) in documents() {
            let dir = tmpdir(&format!("splice-{name}"));
            let file = "hello/triggers/win.lua";

            seed(&dir, &source);
            let at = source.find(", 3)").unwrap() + 2;
            let intent = EditIntent {
                file: file.into(),
                start: at,
                end: at + 1,
                new_text: "5".into(),
                base_hash: None,
            };
            apply_edit(&dir, &intent).unwrap();
            let edited = edited_text(&dir);
            assert_eq!(edited[..at], source[..at], "{name}: bytes before the span");
            assert_eq!(edited[at + 1..], source[at + 1..], "{name}: bytes after the span");

            // an insertion at EOF, exactly as the add-step modal posts it
            seed(&dir, &source);
            let eof = source.len();
            let intent = EditIntent {
                file: file.into(),
                start: eof,
                end: eof,
                new_text: "\t.Do(Objective(\"y\").Complete())\n".into(),
                base_hash: None,
            };
            apply_edit(&dir, &intent).unwrap();
            let edited = edited_text(&dir);
            assert_eq!(edited[..eof], source, "{name}: bytes before the insertion");
            if source.contains("\r\n") {
                let bare = edited.matches('\n').count() - edited.matches("\r\n").count();
                assert_eq!(bare, 0, "{name}: CRLF document gained an LF line: {edited:?}");
            } else {
                assert_eq!(edited.matches('\r').count(), 0, "{name}: LF document gained a CR");
            }
        }
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

    fn intent_json(file: &str, start: usize, end: usize, new_text: &str, hash: &str) -> String {
        serde_json::json!({
            "file": file,
            "start": start,
            "end": end,
            "new_text": new_text,
            "base_hash": hash,
        })
        .to_string()
    }

    /// The ordinary way people use the form: change a field, change another.
    /// Both intents carry the same view generation's hash, both are drained in
    /// one pass, and the second's offsets are stale by the first's length
    /// change. Non-overlapping spans — both must land.
    #[test]
    fn two_edits_from_one_view_generation_both_land() {
        let dir = tmpdir("collide");
        setup(&dir);
        let editor = tmpdir("collide-editor");
        std::fs::create_dir_all(editor.join("edits")).unwrap();
        let mut server = Server::new(dir.clone(), editor.clone(), String::new(), None);

        let file = "hello/triggers/win.lua";
        let source = std::fs::read_to_string(dir.join(file)).unwrap();
        let hash = crate::recognizer::fnv1a(source.as_bytes());
        let count = source.find(", 3)").unwrap() + 2;
        let name = source.find("\"x\"").unwrap();

        std::fs::write(
            editor.join("edits/900_1.json"),
            intent_json(file, count, count + 1, "55", &hash),
        )
        .unwrap();
        std::fs::write(
            editor.join("edits/1000_2.json"),
            intent_json(file, name, name + 3, "\"win\"", &hash),
        )
        .unwrap();

        server.consume_edits();
        let edited = std::fs::read_to_string(dir.join(file)).unwrap();
        assert!(edited.contains(", 55)"), "count edit lost: {edited:?}");
        assert!(edited.contains("Objective(\"win\")"), "name edit lost: {edited:?}");
    }

    /// The safety property: an edit whose OWN region moved underneath it is
    /// still refused, and the file keeps the newer write.
    #[test]
    fn an_edit_whose_own_span_moved_is_still_refused() {
        let dir = tmpdir("overlap");
        setup(&dir);
        let editor = tmpdir("overlap-editor");
        std::fs::create_dir_all(editor.join("edits")).unwrap();
        let mut server = Server::new(dir.clone(), editor.clone(), String::new(), None);

        let file = "hello/triggers/win.lua";
        let source = std::fs::read_to_string(dir.join(file)).unwrap();
        let hash = crate::recognizer::fnv1a(source.as_bytes());
        let chain_start = source.find("When(").unwrap();
        let when_end = source.find(")\n").map(|i| i + 2).unwrap_or(source.len());
        let count = source.find(", 3)").unwrap() + 2;

        // 1: rewrite the whole When line. 2: retune the count inside it.
        std::fs::write(
            editor.join("edits/900_1.json"),
            intent_json(
                file,
                chain_start,
                when_end,
                "When(Team.Player.Has(UnitDef(\"armck\"), 9))\n",
                &hash,
            ),
        )
        .unwrap();
        std::fs::write(
            editor.join("edits/900_2.json"),
            intent_json(file, count, count + 1, "55", &hash),
        )
        .unwrap();

        server.consume_edits();
        let edited = std::fs::read_to_string(dir.join(file)).unwrap();
        assert!(edited.contains("armck\"), 9)"), "first edit lost: {edited:?}");
        assert!(!edited.contains("55"), "stale edit wrote into a moved region: {edited:?}");
        let status = std::fs::read_to_string(editor.join("status.json")).unwrap();
        assert!(status.contains("overlaps"), "{status}");
    }

    /// A rebased edit still faces the grammar gate.
    #[test]
    fn a_rebased_edit_that_breaks_the_grammar_is_rejected() {
        let dir = tmpdir("rebase-grammar");
        setup(&dir);
        let editor = tmpdir("rebase-grammar-editor");
        std::fs::create_dir_all(editor.join("edits")).unwrap();
        let mut server = Server::new(dir.clone(), editor.clone(), String::new(), None);

        let file = "hello/triggers/win.lua";
        let source = std::fs::read_to_string(dir.join(file)).unwrap();
        let hash = crate::recognizer::fnv1a(source.as_bytes());
        let count = source.find(", 3)").unwrap() + 2;
        let name = source.find("\"x\"").unwrap();

        std::fs::write(
            editor.join("edits/900_1.json"),
            intent_json(file, count, count + 1, "55", &hash),
        )
        .unwrap();
        std::fs::write(
            editor.join("edits/900_2.json"),
            intent_json(file, name, name + 3, "function() end", &hash),
        )
        .unwrap();

        server.consume_edits();
        let edited = std::fs::read_to_string(dir.join(file)).unwrap();
        assert!(edited.contains(", 55)"), "{edited:?}");
        assert!(!edited.contains("function"), "{edited:?}");
    }

    /// Intent filenames are `<frame>_<seq>.json`; drained in submission order,
    /// two writes to one field leave the later value.
    #[test]
    fn the_same_field_edited_twice_keeps_the_later_value() {
        let dir = tmpdir("samefield");
        setup(&dir);
        let editor = tmpdir("samefield-editor");
        std::fs::create_dir_all(editor.join("edits")).unwrap();
        let mut server = Server::new(dir.clone(), editor.clone(), String::new(), None);

        let file = "hello/triggers/win.lua";
        let source = std::fs::read_to_string(dir.join(file)).unwrap();
        let hash = crate::recognizer::fnv1a(source.as_bytes());
        let count = source.find(", 3)").unwrap() + 2;

        std::fs::write(
            editor.join("edits/900_1.json"),
            intent_json(file, count, count + 1, "5", &hash),
        )
        .unwrap();
        std::fs::write(
            editor.join("edits/1000_2.json"),
            intent_json(file, count, count + 1, "55", &hash),
        )
        .unwrap();

        server.consume_edits();
        let edited = std::fs::read_to_string(dir.join(file)).unwrap();
        assert!(edited.contains(", 55)"), "later value lost: {edited:?}");
    }

    #[test]
    fn intents_drain_in_numeric_submission_order() {
        let names = ["1000_2.json", "900_1.json", "900_10.json", "900_9.json", "http_5_2.json"];
        let mut paths: Vec<PathBuf> = names.iter().map(PathBuf::from).collect();
        paths.sort_by_key(|p| natural_key(p));
        let sorted: Vec<String> =
            paths.iter().map(|p| p.file_name().unwrap().to_string_lossy().into_owned()).collect();
        assert_eq!(sorted, ["http_5_2.json", "900_1.json", "900_9.json", "900_10.json", "1000_2.json"]);
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

        std::fs::write(editor.join("active_mission.json"), "{\"name\":\"../../etc\"}").unwrap();
        server.follow_active();
        assert_eq!(server.missions_dir, root.join("beta"));

        let mut pinned = Server::new(root.join("alpha"), editor.clone(), String::new(), None);
        std::fs::write(editor.join("active_mission.json"), "{\"name\":\"beta\"}").unwrap();
        pinned.follow_active();
        assert_eq!(pinned.missions_dir, root.join("alpha"));
    }

    #[test]
    fn a_crumb_selection_rescopes_and_survives_the_standing_arm_file() {
        let root = tmpdir("select-root");
        std::fs::create_dir_all(root.join("alpha/triggers")).unwrap();
        std::fs::create_dir_all(root.join("beta/triggers")).unwrap();
        let editor = tmpdir("select-editor");
        let mut server =
            Server::new(root.join("alpha"), editor.clone(), String::new(), Some(root.clone()));

        std::fs::write(editor.join("active_mission.json"), "{\"name\":\"beta\"}").unwrap();
        server.follow_active();
        assert_eq!(server.missions_dir, root.join("beta"));

        std::fs::write(editor.join("select_mission.json"), "{\"name\":\"alpha\"}").unwrap();
        server.consume_select_mission();
        assert_eq!(server.missions_dir, root.join("alpha"));
        assert!(!editor.join("select_mission.json").exists());

        // a standing (unchanged) arm file must not yank the crumb pick back
        server.follow_active();
        assert_eq!(server.missions_dir, root.join("alpha"));

        std::fs::write(editor.join("active_mission.json"), "{\"name\":\"beta\",\"t\":2}").unwrap();
        server.follow_active();
        assert_eq!(server.missions_dir, root.join("beta"));

        std::fs::write(editor.join("select_mission.json"), "{\"name\":\"../../etc\"}").unwrap();
        server.consume_select_mission();
        assert_eq!(server.missions_dir, root.join("beta"));

        let mut pinned = Server::new(root.join("alpha"), editor.clone(), String::new(), None);
        std::fs::write(editor.join("select_mission.json"), "{\"name\":\"beta\"}").unwrap();
        pinned.consume_select_mission();
        assert_eq!(pinned.missions_dir, root.join("alpha"));
        assert!(!editor.join("select_mission.json").exists());
    }

    #[test]
    fn missions_are_listed_by_trigger_presence() {
        let root = tmpdir("list-root");
        std::fs::create_dir_all(root.join("alpha/triggers")).unwrap();
        std::fs::write(root.join("alpha/triggers/win.lua"), "x").unwrap();
        std::fs::create_dir_all(root.join("lib")).unwrap();
        std::fs::create_dir_all(root.join("beta/deep/triggers")).unwrap();
        std::fs::write(root.join("beta/deep/triggers/t.lua"), "x").unwrap();
        let server =
            Server::new(root.join("alpha"), tmpdir("list-editor"), String::new(), Some(root.clone()));
        assert_eq!(server.list_missions(), vec!["alpha".to_string(), "beta".to_string()]);

        let pinned = Server::new(root.join("alpha"), tmpdir("list-editor2"), String::new(), None);
        assert!(pinned.list_missions().is_empty());
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
