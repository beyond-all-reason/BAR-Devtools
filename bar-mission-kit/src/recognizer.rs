//! The subset recognizer: classifies emmylua_parser CST nodes into the
//! decorated mission AST. This walk IS the DSL grammar in the meaningful
//! sense — the single definition of what's form-editable — defined over the
//! same Lua front-end the repo's type checker and language server use
//! (emmylua-analyzer-rust). Check mode is the same walk with findings.

use crate::model::*;
use emmylua_parser::{
    LuaAstNode, LuaCallExpr, LuaChunk, LuaExpr, LuaIndexKey, LuaLiteralToken, LuaParser,
    LuaStat, LuaTableExpr, ParserConfig,
};

/// Chain verbs the framework grammar admits. A statement starts at a bare
/// `When(...)` and ends at its last chained call — no terminator; the chain
/// must contain at least one `Do`. Repeated `.When` AND-composes.
const CHAIN_VERBS: &[&str] = &["When", "Do", "Once", "Debounce"];

pub struct Recognized {
    pub file: FileAst,
    pub findings: Vec<Finding>,
}

pub fn recognize_file(path: &str, source: &str) -> Result<Recognized, String> {
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

    let mut objectives: Vec<String> = Vec::new();
    for group in &mut groups {
        for trigger in &mut group.triggers {
            for step in &mut trigger.steps {
                for arg in &mut step.args {
                    annotate(arg, &mut objectives);
                }
            }
        }
    }
    objectives.sort();
    objectives.dedup();

    Ok(Recognized {
        file: FileAst {
            path: rec.path,
            hash: fnv1a(source.as_bytes()),
            objectives,
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
        self.source[..byte.min(self.source.len())]
            .bytes()
            .filter(|&b| b == b'\n')
            .count()
            + 1
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
                if let Some(trigger) = self.trigger_chain(&call, span, label) {
                    self.groups.last_mut().unwrap().triggers.push(trigger);
                }
            }
            _ => {
                self.mark_opaque(
                    span,
                    "trigger files contain only T.When chains (closure-free surface)",
                );
            }
        }
    }

    /// Recognize `T.When(...).Step(...)...Register()`; None if this call
    /// statement is not a trigger chain (already reported).
    fn trigger_chain(
        &mut self,
        call: &LuaCallExpr,
        span: Span,
        label: Option<String>,
    ) -> Option<Trigger> {
        let unrolled = self.unroll(&LuaExpr::CallExpr(call.clone()), span)?;
        if unrolled.path.len() != 1 || unrolled.path[0] != "When" {
            self.mark_opaque(span, "statement is not a When trigger chain");
            return None;
        }

        // The first invocation is the When itself; later invocations carry
        // their own names (.When/.Do/.Once).
        let mut steps = Vec::new();
        for (i, invocation) in unrolled.calls.into_iter().enumerate() {
            let verb = if i == 0 {
                String::from("When")
            } else {
                match invocation.name.clone() {
                    Some(name) => name,
                    None => {
                        self.mark_opaque(span, "call without a step name in chain");
                        return None;
                    }
                }
            };
            steps.push(Step { verb, span: invocation.span, args: invocation.args, remove_span: (0, 0) });
        }

        // Grammar checks (also the validator's rules). No terminator: the
        // chain ends at its last call; legality means at least one Do.
        if !steps.iter().any(|s| s.verb == "Do") {
            self.finding(span, "trigger chain has no Do — every statement needs at least one effect".into());
        }
        for step in &steps {
            if step.verb == "Register" {
                self.finding(step.span, "Register is gone — chains end at their last Do".into());
            } else if !CHAIN_VERBS.contains(&step.verb.as_str()) {
                self.finding(
                    step.span,
                    format!(
                        "unknown chain verb '{}' (framework grammar: {})",
                        step.verb,
                        CHAIN_VERBS.join("/")
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
            .filter(|s| s.verb == "When")
            .map(|s| line_bounds(self.source, s.span.0, s.span.1).1)
            .unwrap_or(span.0);
        // New .Do lines append past the chain's last line.
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

/// Line bounds around a byte span: (start of first line, past the newline
/// of the last line). The unit of statement/step removal.
fn line_bounds(source: &str, start: usize, end: usize) -> (usize, usize) {
    let s = start.min(source.len());
    let e = end.min(source.len());
    let line_start = source[..s].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let line_end = source[e..].find('\n').map(|i| e + i + 1).unwrap_or(source.len());
    (line_start, line_end)
}

/// The domain annotator: stamp literals with what they MEAN, from the verb
/// tree around them. This is where "the tree walk knows that's a unit
/// definition" lives — the UI turns semantics into controls (the game itself
/// supplies the unit list; the server only names the domain).
fn annotate(value: &mut Value, objectives: &mut Vec<String>) {
    let Value::Verb { path, calls, .. } = value else {
        return;
    };
    let first_string_semantic = match path.as_str() {
        "UnitDef" => Some("unit_def_name"),
        "Objective" => Some("objective_name"),
        _ => None,
    };
    if let Some(sem) = first_string_semantic {
        if let Some(Value::String { value, semantic, .. }) =
            calls.first_mut().and_then(|c| c.args.first_mut())
        {
            *semantic = Some(sem.to_string());
            if sem == "objective_name" {
                objectives.push(value.clone());
            }
        }
    }
    if path.ends_with(".Has") {
        if let Some(Value::Number { semantic, .. }) =
            calls.first_mut().and_then(|c| c.args.get_mut(1))
        {
            *semantic = Some("count".to_string());
        }
    }
    for call in calls {
        for arg in &mut call.args {
            annotate(arg, objectives);
        }
    }
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
