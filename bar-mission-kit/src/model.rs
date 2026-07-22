//! The decorated mission AST: what the recognizer emits and every other
//! consumer (validator, RML form, future write-back) reads. Nodes keep byte
//! spans into the source file so UI edits can resolve to text edits.

use serde::Serialize;

/// Byte span [start, end) into the source file.
pub type Span = (usize, usize);

#[derive(Serialize, Debug)]
pub struct MissionAst {
    /// Recognizer version; bump when the node vocabulary changes.
    pub version: u32,
    /// Monotonic regeneration counter (serve mode); consumers poll this.
    pub generation: u64,
    pub files: Vec<FileAst>,
    /// The authoring surface schema (curated overlay; annotation-derived
    /// later): condition/effect templates the form's add-palette offers.
    pub surface: serde_json::Value,
}

#[derive(Serialize, Debug)]
pub struct FileAst {
    /// Path as given on the command line (mission-relative when a dir walk).
    pub path: String,
    /// FNV-1a hash of the source bytes this AST was built from. Edit intents
    /// carry it back as base_hash: compare-and-swap against clobbering a file
    /// that changed since the view was built.
    pub hash: String,
    /// Every Objective("name") seen in this file — dropdown fodder.
    pub objectives: Vec<String>,
    /// Byte offset where a whole new trigger chain can be appended (EOF).
    pub insert_trigger_at: usize,
    /// Sections in file order. Chains before any `---@group` land in an
    /// unlabeled leading section.
    pub groups: Vec<Group>,
    /// Spans the recognizer refused to classify. Empty in a conforming
    /// trigger file — the validator reports each as an error there.
    pub opaque: Vec<Opaque>,
}

#[derive(Serialize, Debug)]
pub struct Group {
    /// From `---@group("...")`; None for the leading unlabeled section.
    pub label: Option<String>,
    pub triggers: Vec<Trigger>,
}

#[derive(Serialize, Debug)]
pub struct Trigger {
    /// filename:declaration-order — the same identity the runtime stamps.
    pub id: String,
    pub span: Span,
    /// 1-based source line of the chain start (for open-in-editor).
    pub line: usize,
    /// Byte offset where a new `.Do(...)` line can be inserted (start of the
    /// Register step's line). Insert intents use start == end == this.
    pub insert_effect_at: usize,
    /// Whole-statement removal span: chain's first line start to past the
    /// Register line's newline. Replace with "" to delete the trigger.
    pub remove_span: Span,
    /// From a `---@label("...")` directly above the chain.
    pub label: Option<String>,
    pub steps: Vec<Step>,
}

#[derive(Serialize, Debug)]
pub struct Step {
    /// Chain verb: When, AndWhen, Debounce, Once, Do, Register.
    pub verb: String,
    /// The args list INCLUDING parens — replacing it swaps the step's
    /// content: new_text = "(" + template + ")".
    pub span: Span,
    pub args: Vec<Value>,
    /// This step's whole source line (with newline). Replace with "" to
    /// remove the step; the grammar gate protects chain legality.
    pub remove_span: Span,
}

/// An argument node. `kind` discriminates for JSON consumers.
#[derive(Serialize, Debug)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Value {
    Number {
        value: f64,
        span: Span,
        /// Domain meaning ("count", ...) stamped by the annotator.
        #[serde(skip_serializing_if = "Option::is_none")]
        semantic: Option<String>,
    },
    String {
        value: String,
        span: Span,
        /// Domain meaning ("unit_def_name", "objective_name", ...).
        #[serde(skip_serializing_if = "Option::is_none")]
        semantic: Option<String>,
    },
    Boolean {
        value: bool,
        span: Span,
    },
    /// A bare dotted reference, e.g. `Team.Player`.
    Name {
        path: String,
        span: Span,
    },
    /// A verb expression: dotted path + one or more invocations, e.g.
    /// `Objective("x").Complete()` or
    /// `Wave.Define("w").Route(Path("p")).Spawn()`. The first invocation is
    /// the call on the path itself (name = None); later ones are chained.
    Verb {
        path: String,
        calls: Vec<Invocation>,
        span: Span,
    },
    /// A table of literals/refs, e.g. `{ count = 5 }`.
    Table {
        fields: Vec<Field>,
        span: Span,
    },
    /// Anything the subset does not admit (a function body, arithmetic, a
    /// computed index). Validator error in trigger files.
    Opaque {
        span: Span,
        reason: String,
    },
}

#[derive(Serialize, Debug)]
pub struct Invocation {
    /// None for the initial call on the path; Some("Complete") for `.Complete(...)`.
    pub name: Option<String>,
    pub args: Vec<Value>,
    pub span: Span,
}

#[derive(Serialize, Debug)]
pub struct Field {
    /// Named keys only in the subset (`{ count = 5 }`); positional entries
    /// get "1", "2", ...
    pub key: String,
    pub value: Value,
}

#[derive(Serialize, Debug)]
pub struct Opaque {
    pub span: Span,
    pub reason: String,
}

/// A validator finding, printed `path:line: message` in check mode.
#[derive(Debug)]
pub struct Finding {
    pub path: String,
    pub line: usize,
    pub message: String,
}
