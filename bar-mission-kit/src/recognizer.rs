//! The subset recognizer: classifies emmylua_parser CST nodes into the
//! decorated mission AST. The grammar is DERIVED from the game's LuaCATS
//! annotations (crate::types::TypeSurface): statement heads are the injected
//! globals returning a chain class, chain verbs are that class's fields, and
//! slot semantics come from parameter types. A top-level verb the types do
//! not declare is a finding; expressions outside the literal subset stay the
//! opaque exit hatch. Check mode is the same walk with findings.

use crate::model::*;
use crate::types::TypeSurface;
use emmylua_parser::{
    LuaAstNode, LuaCallExpr, LuaChunk, LuaExpr, LuaIndexKey, LuaLiteralToken, LuaParser,
    LuaStat, LuaTableExpr, ParserConfig,
};
use std::collections::BTreeMap;

/// What kind of mission file a path is; the grammar differs slightly by kind.
/// Trigger/roster files are sandbox-injected statement chains. Mode presets
/// are plain modules: an import preamble (VFS.Include + destructure locals)
/// followed by `return Mode(...)...` — same chains, different plumbing.
#[derive(Clone, Copy, PartialEq)]
pub enum FileKind {
    Statements,
    ModePreset,
}

impl FileKind {
    pub fn of(path: &str) -> FileKind {
        if path.contains("modes/") {
            FileKind::ModePreset
        } else {
            FileKind::Statements
        }
    }
}

/// Steps a chain must contain to be executable, per head. The runtime
/// enforces these at Finalize; declaring them keeps check mode's findings
/// aligned. (Not derivable from the types — a required call is semantics.)
const REQUIRED_STEP: &[(&str, &str, &str)] = &[
    ("When", "Do", "trigger chain has no Do — every statement needs at least one effect"),
    ("Spawn", "At", "spawn chain has no At — every spawn needs a position"),
];

pub struct Recognized {
    pub file: FileAst,
    pub findings: Vec<Finding>,
}

/// Recognize against the built-in snapshot surface. Real runs derive the
/// surface from the game tree (TypeSurface::load_near); this entry serves
/// tests and embedded-default consumers.
#[cfg_attr(not(test), allow(dead_code))]
pub fn recognize_file(path: &str, source: &str) -> Result<Recognized, String> {
    recognize_file_with(path, source, TypeSurface::builtin())
}

pub fn recognize_file_with(
    path: &str,
    source: &str,
    surface: &TypeSurface,
) -> Result<Recognized, String> {
    let tree = LuaParser::parse(source, ParserConfig::default());
    let errors = tree.get_errors();
    if !errors.is_empty() {
        return Err(errors
            .iter()
            .map(|e| e.message.to_string())
            .collect::<Vec<_>>()
            .join("; "));
    }

    let mut rec = Rec {
        path: path.to_string(),
        source,
        kind: FileKind::of(path),
        heads: surface.statement_heads(),
        surface,
        groups: vec![Group { label: None, triggers: Vec::new() }],
        opaque: Vec::new(),
        findings: Vec::new(),
        order: 0,
    };

    let chunk: LuaChunk = tree.get_chunk_node();
    if let Some(block) = chunk.get_block() {
        for stat in block.get_stats() {
            rec.statement(&stat);
        }
    }

    // Drop an empty unlabeled leading section if grouped chains exist.
    let mut groups = rec.groups;
    if groups.len() > 1 && groups[0].label.is_none() && groups[0].triggers.is_empty() {
        groups.remove(0);
    }

    // The annotation pass: stamp literal leaves with the semantics their
    // parameter types carry, collecting the nouns as they go by. The roster
    // file is the declaration site for unit/group names; everywhere else a
    // stamped name is a reference to cross-check.
    let mut nouns = Nouns::default();
    let annotator = Annotator {
        surface,
        declares: path.ends_with("units.lua"),
        source,
    };
    for group in &mut groups {
        for trigger in &mut group.triggers {
            let head = trigger.steps.first().map(|s| s.verb.clone()).unwrap_or_default();
            for step in &mut trigger.steps {
                if let Some(sig) = surface.step_sig(&head, &step.verb) {
                    let sig = sig.clone();
                    annotator.stamp_call(&sig, &mut step.args, &mut nouns);
                }
                for arg in &mut step.args {
                    annotator.value(arg, &mut nouns);
                }
            }
        }
    }
    nouns.objectives.sort();
    nouns.objectives.dedup();

    Ok(Recognized {
        file: FileAst {
            path: rec.path,
            hash: fnv1a(source.as_bytes()),
            objectives: nouns.objectives,
            unit_defs: nouns.unit_defs,
            group_defs: nouns.group_defs,
            unit_refs: nouns.unit_refs,
            group_refs: nouns.group_refs,
            insert_trigger_at: source.len(),
            groups,
            opaque: rec.opaque,
        },
        findings: rec.findings,
    })
}

struct Rec<'s> {
    path: String,
    source: &'s str,
    kind: FileKind,
    /// statement head -> chain class, derived from the types.
    heads: BTreeMap<String, String>,
    surface: &'s TypeSurface,
    groups: Vec<Group>,
    opaque: Vec<Opaque>,
    findings: Vec<Finding>,
    order: usize,
}

/// A verb expression unrolled from the nested call CST:
/// base dotted path + invocations in source order.
struct Unrolled {
    path: Vec<String>,
    calls: Vec<Invocation>,
    /// A chained `.Name` seen after a call, waiting for its CallExpr.
    pending: Option<String>,
}

impl<'s> Rec<'s> {
    fn line_of(&self, byte: usize) -> usize {
        line_of(self.source, byte)
    }

    fn finding(&mut self, span: Span, message: String) {
        let line = self.line_of(span.0);
        let path = self.path.clone();
        self.findings.push(Finding { path, line, message });
    }

    fn mark_opaque(&mut self, span: Span, reason: &str) {
        self.finding(span, reason.to_string());
        self.opaque.push(Opaque { span, reason: reason.to_string() });
    }

    fn head_list(&self) -> String {
        self.heads.keys().cloned().collect::<Vec<_>>().join("/")
    }

    fn statement(&mut self, stat: &LuaStat) {
        let span = node_span(stat);
        // Decorators ride the comment lines directly above the statement.
        let decorators = self.leading_decorators(span.0);
        for d in &decorators {
            if d.name == "group" {
                self.groups.push(Group {
                    label: d.args.first().cloned(),
                    triggers: Vec::new(),
                });
            }
        }
        let label = decorators
            .iter()
            .find(|d| d.name == "label")
            .and_then(|d| d.args.first().cloned());

        match stat {
            LuaStat::CallExprStat(call_stat) => {
                let Some(call) = call_stat.get_call_expr() else {
                    self.mark_opaque(span, "unreadable call statement");
                    return;
                };
                if let Some(trigger) = self.statement_chain(&call, span, label) {
                    self.groups.last_mut().unwrap().triggers.push(trigger);
                }
            }
            // Mode presets return their chain; the return IS the statement.
            LuaStat::ReturnStat(ret) if self.kind == FileKind::ModePreset => {
                let exprs: Vec<LuaExpr> = ret.get_expr_list().collect();
                match exprs.as_slice() {
                    [LuaExpr::CallExpr(call)] => {
                        if let Some(trigger) = self.statement_chain(call, span, label) {
                            self.groups.last_mut().unwrap().triggers.push(trigger);
                        }
                    }
                    _ => self.mark_opaque(span, "mode presets return exactly one Mode chain"),
                }
            }
            // Mode presets bind their vocabulary with an import preamble:
            // `local X = VFS.Include(...)` and destructures of such locals.
            // Plumbing, not content — tolerated, not modeled.
            LuaStat::LocalStat(local) if self.kind == FileKind::ModePreset => {
                let imports = local.get_value_exprs().all(|expr| match &expr {
                    LuaExpr::CallExpr(call) => call
                        .get_prefix_expr()
                        .and_then(|p| match p {
                            LuaExpr::IndexExpr(_) | LuaExpr::NameExpr(_) => Some(()),
                            _ => None,
                        })
                        .is_some(),
                    LuaExpr::IndexExpr(_) | LuaExpr::NameExpr(_) => true,
                    _ => false,
                });
                if !imports {
                    self.mark_opaque(span, "mode preset locals may only import vocabulary");
                }
            }
            _ => {
                let message = format!(
                    "mission files contain only verb chains ({}) — closure-free surface",
                    self.head_list()
                );
                self.mark_opaque(span, &message);
            }
        }
    }

    /// Recognize one statement chain against the derived grammar; None if
    /// this call statement is not one (already reported).
    fn statement_chain(
        &mut self,
        call: &LuaCallExpr,
        span: Span,
        label: Option<String>,
    ) -> Option<Trigger> {
        let unrolled = self.unroll(&LuaExpr::CallExpr(call.clone()), span)?;
        let head = unrolled.path.join(".");
        if unrolled.path.len() != 1 || !self.heads.contains_key(&head) {
            let message = format!(
                "unknown statement verb '{head}' — the injected environment declares: {}",
                self.head_list()
            );
            self.mark_opaque(span, &message);
            return None;
        }

        // The first invocation is the head itself; later invocations carry
        // their own names (.When/.Do/.At/...).
        let mut steps = Vec::new();
        for (i, invocation) in unrolled.calls.into_iter().enumerate() {
            let verb = if i == 0 {
                head.clone()
            } else {
                match invocation.name.clone() {
                    Some(name) => name,
                    None => {
                        self.mark_opaque(span, "call without a step name in chain");
                        return None;
                    }
                }
            };
            let line = self.line_of(invocation.span.0);
            steps.push(Step { verb, line, span: invocation.span, args: invocation.args, remove_span: (0, 0) });
        }

        // Grammar checks (also the validator's rules). No terminator: the
        // chain ends at its last call.
        for (required_head, required_verb, message) in REQUIRED_STEP {
            if head == *required_head && !steps.iter().any(|s| s.verb == *required_verb) {
                self.finding(span, message.to_string());
            }
        }
        let chain_verbs = self.surface.chain_verbs(&head);
        for step in steps.iter().skip(1) {
            if step.verb == "Register" {
                self.finding(step.span, "Register is gone — chains end at their last Do".into());
            } else if !chain_verbs.iter().any(|v| v == &step.verb) {
                self.finding(
                    step.span,
                    format!(
                        "unknown chain verb '{}' after {head} (the {head} chain declares: {})",
                        step.verb,
                        chain_verbs.join("/")
                    ),
                );
            }
        }

        self.order += 1;
        for step in &mut steps {
            step.remove_span = line_bounds(self.source, step.span.0, step.span.1);
        }
        let insert_condition_at = steps
            .first()
            .filter(|s| s.verb == head)
            .map(|s| line_bounds(self.source, s.span.0, s.span.1).1)
            .unwrap_or(span.0);
        // New chained lines append past the chain's last line.
        let insert_effect_at = line_bounds(self.source, span.0, span.1).1;
        Some(Trigger {
            id: format!("{}:{}", self.path, self.order),
            span,
            line: self.line_of(span.0),
            insert_effect_at,
            insert_condition_at,
            remove_span: line_bounds(self.source, span.0, span.1),
            label,
            steps,
        })
    }

    /// Unroll a nested call/index expression into base path + invocations.
    /// Returns None (with a finding) when the shape leaves the subset.
    fn unroll(&mut self, expr: &LuaExpr, span: Span) -> Option<Unrolled> {
        match expr {
            LuaExpr::NameExpr(name) => {
                let text = name.get_name_text()?;
                Some(Unrolled { path: vec![text.to_string()], calls: Vec::new(), pending: None })
            }
            LuaExpr::IndexExpr(index) => {
                let prefix = index.get_prefix_expr()?;
                let mut unrolled = self.unroll(&prefix, span)?;
                let key = match index.get_index_key() {
                    Some(LuaIndexKey::Name(token)) => token.get_name_text().to_string(),
                    _ => {
                        self.mark_opaque(span, "computed index in reference");
                        return None;
                    }
                };
                if unrolled.calls.is_empty() && unrolled.pending.is_none() {
                    unrolled.path.push(key);
                } else if unrolled.pending.is_none() {
                    unrolled.pending = Some(key);
                } else {
                    self.mark_opaque(span, "nested index between chained calls");
                    return None;
                }
                Some(unrolled)
            }
            LuaExpr::CallExpr(call) => {
                if call.is_colon_call() {
                    self.mark_opaque(span, "method (colon) call — the surface is dot-only");
                    return None;
                }
                let prefix = call.get_prefix_expr()?;
                let mut unrolled = self.unroll(&prefix, span)?;
                let args = self.call_args(call);
                // A nested CallExpr spans its whole prefix chain; the args
                // list is the part that belongs to THIS invocation.
                let call_span = call
                    .get_args_list()
                    .map(|list| node_span(&list))
                    .unwrap_or_else(|| node_span(call));
                let name = unrolled.pending.take();
                unrolled.calls.push(Invocation { name, args, span: call_span });
                Some(unrolled)
            }
            _ => {
                self.mark_opaque(span, "expression outside the mission subset");
                None
            }
        }
    }

    fn call_args(&mut self, call: &LuaCallExpr) -> Vec<Value> {
        let Some(list) = call.get_args_list() else {
            return Vec::new();
        };
        list.get_args().map(|arg| self.value(&arg)).collect()
    }

    /// Classify one expression into the subset's value vocabulary.
    fn value(&mut self, expr: &LuaExpr) -> Value {
        let span = node_span(expr);
        match expr {
            LuaExpr::LiteralExpr(literal) => match literal.get_literal() {
                Some(LuaLiteralToken::Number(number)) => {
                    use emmylua_parser::NumberResult;
                    let value = match number.get_number_value() {
                        NumberResult::Int(i) => i as f64,
                        NumberResult::Uint(u) => u as f64,
                        NumberResult::Float(f) => f,
                        NumberResult::Number => f64::NAN,
                    };
                    Value::Number { value, span, semantic: None }
                }
                Some(LuaLiteralToken::String(string)) => Value::String {
                    value: string.get_value(),
                    span,
                    semantic: None,
                },
                Some(LuaLiteralToken::Bool(b)) => Value::Boolean {
                    value: b.is_true(),
                    span,
                },
                _ => self.opaque_value(span, "unsupported literal"),
            },
            LuaExpr::TableExpr(table) => self.table(table, span),
            LuaExpr::NameExpr(_) | LuaExpr::IndexExpr(_) | LuaExpr::CallExpr(_) => {
                let Some(unrolled) = self.unroll(expr, span) else {
                    return Value::Opaque { span, reason: "unrecognized reference".into() };
                };
                if unrolled.pending.is_some() {
                    return self.opaque_value(span, "dangling index after a call");
                }
                let path = unrolled.path.join(".");
                if unrolled.calls.is_empty() {
                    Value::Name { path, span }
                } else {
                    Value::Verb { path, calls: unrolled.calls, span }
                }
            }
            LuaExpr::ClosureExpr(_) => self.opaque_value(
                span,
                "function body in a trigger file — build the effect with a named verb (closure-free surface)",
            ),
            // Negative number literals (`-1`): the parser sees unary minus.
            LuaExpr::UnaryExpr(unary) => {
                let negated_number = unary
                    .get_op_token()
                    .map(|op| op.get_op() == emmylua_parser::UnaryOperator::OpUnm)
                    .unwrap_or(false)
                    .then(|| unary.get_expr())
                    .flatten()
                    .and_then(|inner| match self.value(&inner) {
                        Value::Number { value, .. } => Some(value),
                        _ => None,
                    });
                match negated_number {
                    Some(value) => Value::Number { value: -value, span, semantic: None },
                    None => self.opaque_value(span, "expression outside the mission subset"),
                }
            }
            _ => self.opaque_value(span, "expression outside the mission subset"),
        }
    }

    fn opaque_value(&mut self, span: Span, reason: &str) -> Value {
        self.finding(span, reason.to_string());
        Value::Opaque { span, reason: reason.to_string() }
    }

    fn table(&mut self, table: &LuaTableExpr, span: Span) -> Value {
        let mut fields = Vec::new();
        let mut index = 0usize;
        for field in table.get_fields() {
            let value = match field.get_value_expr() {
                Some(expr) => self.value(&expr),
                None => self.opaque_value(node_span(&field), "table field without a value"),
            };
            let key = match field.get_field_key() {
                Some(LuaIndexKey::Name(token)) => token.get_name_text().to_string(),
                Some(LuaIndexKey::String(s)) => s.get_value(),
                None => {
                    index += 1;
                    index.to_string()
                }
                _ => String::from("?"),
            };
            fields.push(Field { key, value });
        }
        Value::Table { fields, span }
    }

    /// Parse `---@group("Wave timing")` style decorators from the comment
    /// lines directly above `start_byte`. Comment decorators are grammar, not
    /// hints — but unknown names are ignored (forward compatibility).
    fn leading_decorators(&self, start_byte: usize) -> Vec<Decorator> {
        let head = &self.source[..start_byte.min(self.source.len())];
        let mut out = Vec::new();
        for line in head.lines().rev() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let Some(rest) = trimmed.strip_prefix("---@") else {
                break; // first non-decorator line ends the run
            };
            let (name, args_text) = match rest.split_once('(') {
                Some((n, a)) => (n.trim(), a.trim_end_matches(')')),
                None => (rest.trim(), ""),
            };
            let args = args_text
                .split(',')
                .map(|a| a.trim().trim_matches('"').to_string())
                .filter(|a| !a.is_empty())
                .collect();
            out.push(Decorator { name: name.to_string(), args });
        }
        out.reverse();
        out
    }
}

struct Decorator {
    name: String,
    args: Vec<String>,
}

//------------------------------------------------------------------------------
// The type-driven annotator: semantics come from parameter types. A declared
// alias becomes the slot's semantic (UnitDefName -> unit_def_name); a plain
// number parameter falls back to its name (count). Vocabulary the types do
// not cover is simply left unstamped — the custom exit hatch.
//------------------------------------------------------------------------------

#[derive(Default)]
struct Nouns {
    objectives: Vec<String>,
    unit_defs: Vec<String>,
    group_defs: Vec<String>,
    unit_refs: Vec<NameRef>,
    group_refs: Vec<NameRef>,
}

struct Annotator<'s> {
    surface: &'s TypeSurface,
    /// units.lua declares names; every other file references them.
    declares: bool,
    source: &'s str,
}

impl<'s> Annotator<'s> {
    /// Stamp one invocation's literal args from a signature, positionally.
    fn stamp_call(&self, sig: &crate::types::FnSig, args: &mut [Value], nouns: &mut Nouns) {
        for (param, arg) in sig.params.iter().zip(args.iter_mut()) {
            let (name, type_name) = param;
            match arg {
                Value::String { value, span, semantic } => {
                    if let Some(slug) = self.surface.semantic_for(type_name) {
                        self.collect(&slug, value, span.0, nouns);
                        *semantic = Some(slug);
                    }
                }
                Value::Number { semantic, .. } => {
                    let slug = self
                        .surface
                        .semantic_for(type_name)
                        .unwrap_or_else(|| name.clone());
                    *semantic = Some(slug);
                }
                _ => {}
            }
        }
    }

    fn collect(&self, slug: &str, value: &str, at: usize, nouns: &mut Nouns) {
        match slug {
            "objective_name" => nouns.objectives.push(value.to_string()),
            "unit_name" => {
                if self.declares {
                    nouns.unit_defs.push(value.to_string());
                } else {
                    nouns.unit_refs.push(NameRef {
                        name: value.to_string(),
                        line: line_of(self.source, at),
                    });
                }
            }
            "unit_group" => {
                if self.declares {
                    nouns.group_defs.push(value.to_string());
                } else {
                    nouns.group_refs.push(NameRef {
                        name: value.to_string(),
                        line: line_of(self.source, at),
                    });
                }
            }
            _ => {}
        }
    }

    /// Annotate one value tree: resolve verb paths through the type surface,
    /// stamping each invocation's args from the signature it lands on, then
    /// recurse into every argument.
    fn value(&self, value: &mut Value, nouns: &mut Nouns) {
        let Value::Verb { path, calls, .. } = value else {
            return;
        };
        let mut current: Option<crate::types::FnSig> = self.surface.resolve_path(path);
        for call in calls.iter_mut() {
            let sig = match &call.name {
                None => current.clone(),
                Some(name) => current
                    .as_ref()
                    .and_then(|prev| prev.ret.as_deref())
                    .and_then(|class| self.surface.member_sig(class, name))
                    .cloned(),
            };
            if let Some(sig) = &sig {
                self.stamp_call(sig, &mut call.args, nouns);
            }
            if call.name.is_some() {
                current = sig;
            }
            for arg in &mut call.args {
                self.value(arg, nouns);
            }
        }
    }
}

fn line_of(source: &str, byte: usize) -> usize {
    source[..byte.min(source.len())]
        .bytes()
        .filter(|&b| b == b'\n')
        .count()
        + 1
}

/// Line bounds around a byte span: (start of first line, past the newline
/// of the last line). The unit of statement/step removal.
fn line_bounds(source: &str, start: usize, end: usize) -> (usize, usize) {
    let s = start.min(source.len());
    let e = end.min(source.len());
    let line_start = source[..s].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let line_end = source[e..].find('\n').map(|i| e + i + 1).unwrap_or(source.len());
    (line_start, line_end)
}

/// Stable content hash (FNV-1a 64) for the CAS precondition on edits.
pub fn fnv1a(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn node_span<N: LuaAstNode>(node: &N) -> Span {
    let range = node.get_range();
    (usize::from(range.start()), usize::from(range.end()))
}
