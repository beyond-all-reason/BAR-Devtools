//! The subset recognizer: classifies emmylua_parser CST nodes into the
//! decorated mission AST. The grammar is DERIVED from the game's LuaCATS
//! annotations (crate::types::TypeSurface): statement heads are the injected
//! globals returning a chain class, chain verbs are that class's fields, and
//! slot semantics come from parameter types. A top-level verb the types do
//! not declare is a finding; expressions outside the literal subset stay the
//! opaque exit hatch. Check mode is the same walk with findings.
//!
//! The subset is real Lua: a `local` may bind any value the grammar admits,
//! anywhere in the file, and a later reference to it reads as the value it
//! names — `local pawn = UnitDef("armpw")` then `Spawn(pawn, ...)`. What stays
//! out is control flow and function bodies, not statement placement.

use crate::model::*;
use crate::types::TypeSurface;
use emmylua_parser::{
    LuaAstNode, LuaCallExpr, LuaChunk, LuaExpr, LuaIndexKey, LuaLiteralToken, LuaParser, LuaStat,
    LuaTableExpr, LuaVarExpr, ParserConfig,
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
    /// objectives.lua at the mission root: the objective definition site,
    /// Objective declaration chains — the runtime injects a different env
    /// there, and so does the recognizer.
    Objectives,
    /// variables.lua at the mission root: typed slots, Variable chains.
    Variables,
}

impl FileKind {
    pub fn of(path: &str) -> FileKind {
        // By path COMPONENT, and either separator. A substring test for
        // "modes/" reads false on Windows, where the display path arrives with
        // backslashes, and true for a directory merely ending in the word —
        // "gamemodes/" is not a preset directory.
        let preset = path
            .split(|c| c == '/' || c == '\\')
            .any(|component| component == "modes");
        if preset {
            FileKind::ModePreset
        } else if is_objectives(path) {
            FileKind::Objectives
        } else if is_definition_site(path, "variables.lua") {
            FileKind::Variables
        } else {
            FileKind::Statements
        }
    }
}

/// The mission-root objectives.lua — the definition site. A trigger file
/// that happens to be called objectives.lua is still a trigger file.
pub fn is_objectives(path: &str) -> bool {
    is_definition_site(path, "objectives.lua")
}

/// A mission-root definition file by name (units.lua, objectives.lua,
/// variables.lua): the basename matches and it is not under triggers/ or modes/.
pub fn is_definition_site(path: &str, name: &str) -> bool {
    let components: Vec<&str> = path.split(|c| c == '/' || c == '\\').collect();
    components.last() == Some(&name)
        && !components.iter().any(|c| *c == "triggers" || *c == "modes")
}

/// Steps a chain must contain to be executable, per head. The runtime
/// enforces these at Finalize; declaring them keeps check mode's findings
/// aligned. (Not derivable from the types — a required call is semantics.)
const REQUIRED_STEP: &[(&str, &str, &str)] = &[
    (
        "When",
        "Do",
        "trigger chain has no Do — every statement needs at least one effect",
    ),
    (
        "Spawn",
        "At",
        "spawn chain has no At — every spawn needs a position",
    ),
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

    let kind = FileKind::of(path);
    // The heads ARE the sandbox: the definition site speaks declarations,
    // everything else speaks the statement grammar.
    let heads = match kind {
        FileKind::Objectives => surface.objective_heads(),
        FileKind::Variables => surface.variable_heads(),
        _ => surface.statement_heads(),
    };
    let mut rec = Rec {
        path: path.to_string(),
        source,
        kind,
        heads: heads.clone(),
        surface,
        groups: vec![Group {
            label: None,
            triggers: Vec::new(),
        }],
        opaque: Vec::new(),
        findings: Vec::new(),
        order: 0,
        bindings: BTreeMap::new(),
        exports: Vec::new(),
        imports: BTreeMap::new(),
    };

    let chunk: LuaChunk = tree.get_chunk_node();
    if let Some(block) = chunk.get_block() {
        for stat in block.get_stats() {
            rec.statement(&stat);
        }
    }

    // Exports: what the other files may reference by key. A unit export
    // without Named takes its key as its name (the runtime does the same),
    // so the key is also a declaration the cross-check must accept.
    let mut unit_exports = Vec::new();
    let mut objective_exports = Vec::new();
    let mut group_exports = Vec::new();
    let mut variable_exports = Vec::new();
    let mut exports = Vec::new();
    for (key, value, span) in &rec.exports {
        let line = line_of(source, span.0);
        let first_string =
            |calls: &[crate::model::Invocation]| match calls.first().and_then(|c| c.args.first()) {
                Some(Value::String { value, .. }) => Some(value.clone()),
                _ => None,
            };
        // Anything exports. A handle exports under its wire name; the class
        // the value resolves to is what the other side may say about it.
        let (name, kind) = match value {
            Value::Verb { path, calls, .. } if path == "Objective" => {
                (first_string(calls), "objective")
            }
            Value::Verb { path, calls, .. } if path == "Spawn" || path == "Claim" => {
                let named = calls
                    .iter()
                    .find(|c| c.name.as_deref() == Some("Named"))
                    .and_then(|c| match c.args.first() {
                        Some(Value::String { value, .. }) => Some(value.clone()),
                        _ => None,
                    });
                (Some(named.unwrap_or_else(|| key.clone())), "unit")
            }
            Value::Verb { path, calls, .. } if path == "Group" => (first_string(calls), "group"),
            Value::Verb { path, calls, .. } if path == "Variable" => {
                (first_string(calls), "variable")
            }
            _ => (None, "value"),
        };
        let export = Export {
            key: key.clone(),
            name: name.clone().unwrap_or_else(|| key.clone()),
            line,
            class: surface.value_class(value),
        };
        if name.is_some() {
            match kind {
                "objective" => objective_exports.push(export.clone()),
                "unit" => unit_exports.push(export.clone()),
                "group" => group_exports.push(export.clone()),
                "variable" => variable_exports.push(export.clone()),
                _ => {}
            }
        }
        exports.push(export);
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
        imports: &rec.imports,
    };
    for group in &mut groups {
        for trigger in &mut group.triggers {
            let head = trigger
                .steps
                .first()
                .map(|s| s.verb.clone())
                .unwrap_or_default();
            for step in &mut trigger.steps {
                // The head resolves through its global; chained verbs through
                // the head's chain class — the same split the runtime's env
                // makes, and the only resolution that works for the
                // definition site (whose global returns the OTHER surface).
                let sig = if step.verb == head {
                    surface.step_sig(&head, &head).cloned()
                } else {
                    heads
                        .get(&head)
                        .and_then(|class| surface.member_sig(class, &step.verb))
                        .cloned()
                };
                if let Some(sig) = sig {
                    // The definition site's head argument IS the declaration;
                    // every other objective id anywhere is a reference.
                    let declares_objective = kind == FileKind::Objectives && step.verb == head;
                    annotator.stamp_call_as(&sig, &mut step.args, &mut nouns, declares_objective);
                }
                for arg in &mut step.args {
                    annotator.value(arg, &mut nouns);
                }
            }
        }
    }
    if annotator.declares {
        for export in &unit_exports {
            if !nouns.unit_defs.contains(&export.name) {
                nouns.unit_defs.push(export.name.clone());
            }
        }
        for export in &group_exports {
            if !nouns.group_defs.contains(&export.name) {
                nouns.group_defs.push(export.name.clone());
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
            objective_defs: nouns.objective_defs,
            objective_refs: nouns.objective_refs,
            unit_defs: nouns.unit_defs,
            group_defs: nouns.group_defs,
            unit_refs: nouns.unit_refs,
            group_refs: nouns.group_refs,
            unit_exports,
            objective_exports,
            group_exports,
            variable_exports,
            exports,
            imports: rec.imports.clone(),
            export_refs: nouns.export_refs,
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
    /// Locals bound so far, in file order: name -> the value it names. A
    /// reference to one reads as that value, spans pointing at the binding.
    bindings: BTreeMap<String, Value>,
    /// The file's `return { key = local }`: key -> the bound value.
    exports: Vec<(String, Value, Span)>,
    /// `local X = VFS.Include("<path>")`: alias -> the included file.
    imports: BTreeMap<String, String>,
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
        self.findings.push(Finding {
            path,
            line,
            message,
            span: None,
        });
    }

    fn mark_opaque(&mut self, span: Span, reason: &str) {
        self.finding(span, reason.to_string());
        self.opaque.push(Opaque {
            span,
            reason: reason.to_string(),
        });
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
            // A definition file returns its handles: `return { hub = hub }`.
            // The key is the Lua name the other files reference it by.
            LuaStat::ReturnStat(ret) if self.kind != FileKind::ModePreset => {
                let exprs: Vec<LuaExpr> = ret.get_expr_list().collect();
                match exprs.as_slice() {
                    [LuaExpr::TableExpr(table)] => {
                        for field in table.get_fields() {
                            let key = match field.get_field_key() {
                                Some(LuaIndexKey::Name(token)) => token.get_name_text().to_string(),
                                _ => {
                                    self.finding(
                                        span,
                                        "an export needs a name: `return { hub = hub }`".into(),
                                    );
                                    continue;
                                }
                            };
                            let value = match field.get_value_expr() {
                                Some(expr) => self.value(&expr),
                                None => continue,
                            };
                            let field_span = node_span(&field);
                            self.exports.push((key, value, field_span));
                        }
                    }
                    _ => self.mark_opaque(
                        span,
                        "a mission file returns a table of its own handles, or nothing",
                    ),
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
            // A local binds a name to a value of the subset; the reference
            // later reads as that value. Presets bind their vocabulary this
            // way (`local X = VFS.Include(...)`, then destructures) — the same
            // rule, nothing special-cased.
            LuaStat::LocalStat(local) => {
                let names: Vec<String> = local
                    .get_local_name_list()
                    .filter_map(|n| n.get_name_token().map(|t| t.get_name_text().to_string()))
                    .collect();
                let values: Vec<LuaExpr> = local.get_value_exprs().collect();
                for (i, name) in names.into_iter().enumerate() {
                    match values.get(i) {
                        Some(expr) => {
                            let value = self.value(expr);
                            if let Value::Verb { path, calls, .. } = &value {
                                if path == "VFS.Include" {
                                    if let Some(Value::String {
                                        value: included, ..
                                    }) = calls.first().and_then(|c| c.args.first())
                                    {
                                        self.imports.insert(name.clone(), included.clone());
                                    }
                                }
                            }
                            self.bindings.insert(name, value);
                        }
                        None => self.finding(span, format!("local '{name}' binds no value")),
                    }
                }
            }
            // Rebinding a local is still the subset; assigning anything else
            // reaches outside the sandbox.
            LuaStat::AssignStat(assign) => {
                let (vars, exprs) = assign.get_var_and_expr_list();
                for (i, var) in vars.into_iter().enumerate() {
                    let name = match &var {
                        LuaVarExpr::NameExpr(name) => name.get_name_text(),
                        LuaVarExpr::IndexExpr(_) => None,
                    };
                    match (name, exprs.get(i)) {
                        (Some(name), Some(expr)) if self.bindings.contains_key(&name) => {
                            let value = self.value(expr);
                            self.bindings.insert(name, value);
                        }
                        (Some(name), _) => self.mark_opaque(
                            span,
                            &format!("assignment to '{name}', which no local declared — the sandbox has no globals to set"),
                        ),
                        (None, _) => self.mark_opaque(span, "indexed assignment outside the mission subset"),
                    }
                }
            }
            _ => {
                let message = format!(
                    "mission files are verb chains ({}) and the locals that name their values — no control flow, no function bodies",
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
            steps.push(Step {
                verb,
                line,
                span: invocation.span,
                args: invocation.args,
                remove_span: (0, 0),
            });
        }

        // Grammar checks (also the validator's rules). No terminator: the
        // chain ends at its last call.
        for (required_head, required_verb, message) in REQUIRED_STEP {
            if head == *required_head && !steps.iter().any(|s| s.verb == *required_verb) {
                self.finding(span, message.to_string());
            }
        }
        // Through the per-kind heads map, so the definition site's chain
        // resolves against its declaration class, not the trigger surface.
        let chain_verbs = self
            .heads
            .get(&head)
            .map(|class| self.surface.class_field_names(class))
            .unwrap_or_default();
        for step in steps.iter().skip(1) {
            if step.verb == "Register" {
                self.finding(
                    step.span,
                    "Register is gone — chains end at their last Do".into(),
                );
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
                Some(Unrolled {
                    path: vec![text.to_string()],
                    calls: Vec::new(),
                    pending: None,
                })
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
                unrolled.calls.push(Invocation {
                    name,
                    args,
                    span: call_span,
                });
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
                // An import alias is a reference into another file, resolved
                // by the annotator against that file's exports — not a value
                // to substitute.
                if !self.imports.contains_key(&unrolled.path[0]) {
                    if let Some(bound) = self.bindings.get(&unrolled.path[0]).cloned() {
                        return self.through_binding(bound, unrolled, span);
                    }
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

    /// A reference whose base is a bound local reads as the bound value,
    /// with whatever the reference chains onto it: `pawn` is the UnitDef,
    /// `obj.IsComplete()` is the objective's chain continued.
    fn through_binding(&mut self, bound: Value, unrolled: Unrolled, span: Span) -> Value {
        let rest = &unrolled.path[1..];
        let mut calls = unrolled.calls;
        match bound {
            Value::Verb {
                path,
                calls: mut bound_calls,
                span: bound_span,
            } => {
                // `alias.Verb(...)` unrolls as path [alias, Verb] + an unnamed
                // call: the segment names the invocation on the bound chain.
                if rest.len() == 1 && calls.first().map(|c| c.name.is_none()).unwrap_or(false) {
                    calls[0].name = Some(rest[0].clone());
                    bound_calls.extend(calls);
                    return Value::Verb {
                        path,
                        calls: bound_calls,
                        span: bound_span,
                    };
                }
                if rest.is_empty() && calls.is_empty() {
                    return Value::Verb {
                        path,
                        calls: bound_calls,
                        span: bound_span,
                    };
                }
                if calls.is_empty() {
                    // A field off a bound call — a preset's `ModeDSL.Mode` off
                    // `VFS.Include(...)` — is a reference by the alias's own
                    // name; the surface resolves it or leaves it unstamped.
                    return Value::Name {
                        path: unrolled.path.join("."),
                        span,
                    };
                }
                if rest.is_empty() {
                    return self.opaque_value(
                        span,
                        "calling a bound value — chain a verb onto it instead",
                    );
                }
                self.opaque_value(span, "nested index into a bound value")
            }
            Value::Name { path, span: _ } => {
                let mut full = vec![path];
                full.extend(rest.iter().cloned());
                let path = full.join(".");
                if calls.is_empty() {
                    Value::Name { path, span }
                } else {
                    Value::Verb { path, calls, span }
                }
            }
            literal @ (Value::String { .. }
            | Value::Number { .. }
            | Value::Boolean { .. }
            | Value::Table { .. }) => {
                if !rest.is_empty() || !calls.is_empty() {
                    return self.opaque_value(span, "a bound literal takes no index or call");
                }
                literal
            }
            Value::Opaque { reason, .. } => Value::Opaque { span, reason },
        }
    }

    fn opaque_value(&mut self, span: Span, reason: &str) -> Value {
        self.finding(span, reason.to_string());
        Value::Opaque {
            span,
            reason: reason.to_string(),
        }
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
            out.push(Decorator {
                name: name.to_string(),
                args,
            });
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
    objective_defs: Vec<String>,
    objective_refs: Vec<NameRef>,
    unit_defs: Vec<String>,
    group_defs: Vec<String>,
    unit_refs: Vec<NameRef>,
    group_refs: Vec<NameRef>,
    export_refs: Vec<ExportRef>,
}

struct Annotator<'s> {
    surface: &'s TypeSurface,
    /// units.lua declares names; every other file references them.
    declares: bool,
    source: &'s str,
    /// alias -> included file, from `local X = VFS.Include(...)`.
    imports: &'s BTreeMap<String, String>,
}

impl<'s> Annotator<'s> {
    /// Stamp one invocation's literal args from a signature, positionally.
    fn stamp_call(&self, sig: &crate::types::FnSig, args: &mut [Value], nouns: &mut Nouns) {
        self.stamp_call_as(sig, args, nouns, false);
    }

    /// As stamp_call; `declares_objective` marks this invocation the
    /// objective definition site (an objectives.lua head), so its id lands
    /// in defs instead of refs.
    fn stamp_call_as(
        &self,
        sig: &crate::types::FnSig,
        args: &mut [Value],
        nouns: &mut Nouns,
        declares_objective: bool,
    ) {
        for (param, arg) in sig.params.iter().zip(args.iter_mut()) {
            let (name, type_name) = param;
            match arg {
                Value::String {
                    value,
                    span,
                    semantic,
                } => {
                    if let Some(slug) = self.surface.semantic_for(type_name) {
                        self.collect(&slug, value, span.0, nouns, declares_objective);
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

    fn collect(
        &self,
        slug: &str,
        value: &str,
        at: usize,
        nouns: &mut Nouns,
        declares_objective: bool,
    ) {
        match slug {
            "objective_name" => {
                nouns.objectives.push(value.to_string());
                if declares_objective {
                    nouns.objective_defs.push(value.to_string());
                } else {
                    nouns.objective_refs.push(NameRef {
                        name: value.to_string(),
                        line: line_of(self.source, at),
                    });
                }
            }
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
        // `Units.hub` where `local Units = VFS.Include(".../units.lua")`: a
        // reference to that file's export. It reads as the Unit or Objective
        // surface — by which definition file was included — and the verb folds
        // into the dotted path (`Units.hub.IsSpotted`, as `Team.Player.Has`).
        let export_of = |path: &str| -> Option<(&'static str, String, String, Option<String>)> {
            let parts: Vec<&str> = path.split('.').collect();
            let file = self.imports.get(*parts.first()?)?;
            let head = if file.ends_with("units.lua") {
                "Unit"
            } else if file.ends_with("objectives.lua") {
                "Objective"
            } else if file.ends_with("variables.lua") {
                "Variable"
            } else {
                return None;
            };
            match parts.as_slice() {
                [_, key] => Some((head, file.clone(), key.to_string(), None)),
                [_, key, member] => Some((
                    head,
                    file.clone(),
                    key.to_string(),
                    Some(member.to_string()),
                )),
                _ => None,
            }
        };
        if let Value::Name { path, span } = value {
            if let Some((_, file, key, _)) = export_of(path) {
                nouns.export_refs.push(ExportRef {
                    file,
                    key,
                    line: line_of(self.source, span.0),
                });
            }
            return;
        }
        let Value::Verb { path, calls, span } = value else {
            return;
        };
        let mut current: Option<crate::types::FnSig> = match export_of(path) {
            Some((head, file, key, member)) => {
                nouns.export_refs.push(ExportRef {
                    file,
                    key,
                    line: line_of(self.source, span.0),
                });
                let handle = self.surface.resolve_path(head);
                match member {
                    None => handle,
                    Some(name) => handle
                        .as_ref()
                        .and_then(|h| h.ret.as_deref())
                        .and_then(|class| self.surface.member_sig(class, &name))
                        .cloned(),
                }
            }
            None => self.surface.resolve_path(path),
        };
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
    let line_end = source[e..]
        .find('\n')
        .map(|i| e + i + 1)
        .unwrap_or(source.len());
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

#[cfg(test)]
mod tests {
    use super::*;

    fn findings(r: &Recognized) -> Vec<String> {
        r.findings.iter().map(|f| f.message.clone()).collect()
    }

    #[test]
    fn a_preset_keeps_its_lock_modifiers_on_the_verbs_line() {
        // Presets are exempt from stylua so `.Ranked(false).Locked()` stays one
        // line: the modifier binds to the verb before it. The comment is trivia
        // and the joined links are the same chain.
        let src = "local ModeDSL = VFS.Include(\"modules/raptors/mode_dsl.lua\") ---@type RaptorsModeDSL\nlocal Mode, Raptors = ModeDSL.Mode, ModeDSL.Raptors\n\n-- stylua: ignore\nreturn Mode(\"Raptors\")\n\t.Desc(\"Hold out.\")\n\t.Bot(\"RaptorsAI\")\n\t.Ranked(false).Locked()\n\t.Difficulty(Raptors.Swarm, \"normal\").Unlocked()\n\t.Boss(Raptors.Swarm, 1)\n";
        // The module's own mode grammar, as load_near_policy composes it.
        let surface = crate::types::TypeSurface::parse(&[include_str!(
            "../fixtures/modules/raptors/types/mode_policy.lua"
        )]);
        let r = recognize_file_with("raptors/modes/raptors.lua", src, &surface).unwrap();
        assert!(findings(&r).is_empty(), "{:?}", findings(&r));
        let steps: Vec<&str> = r.file.groups[0].triggers[0]
            .steps
            .iter()
            .map(|s| s.verb.as_str())
            .collect();
        assert_eq!(
            steps,
            vec![
                "Mode",
                "Desc",
                "Bot",
                "Ranked",
                "Locked",
                "Difficulty",
                "Unlocked",
                "Boss"
            ]
        );
    }

    #[test]
    fn a_local_unit_def_reads_as_the_unit_def_it_names() {
        let src = "local pawn = UnitDef(\"armpw\")\nSpawn(pawn, \"player\").At(0.5, 0.5).Named(\"scout\")\n";
        let r = recognize_file("t/units.lua", src).unwrap();
        assert!(findings(&r).is_empty(), "{:?}", findings(&r));
        let step = &r.file.groups[0].triggers[0].steps[0];
        match &step.args[0] {
            Value::Verb { path, calls, .. } => {
                assert_eq!(path, "UnitDef");
                assert!(
                    matches!(&calls[0].args[0], Value::String { value, semantic: Some(s), .. } if value == "armpw" && s == "unit_def_name")
                );
            }
            other => panic!("expected the bound UnitDef, got {other:?}"),
        }
    }

    #[test]
    fn a_local_objective_chains_on_where_it_is_used() {
        let src = "local found = Objective(\"find_the_enclave\")\nWhen(found.IsComplete()).Do(found.Reveal())\n";
        let r = recognize_file("t/triggers/a.lua", src).unwrap();
        assert!(findings(&r).is_empty(), "{:?}", findings(&r));
        let when = &r.file.groups[0].triggers[0].steps[0];
        match &when.args[0] {
            Value::Verb { path, calls, .. } => {
                assert_eq!(path, "Objective");
                assert_eq!(calls.len(), 2);
                assert_eq!(calls[1].name.as_deref(), Some("IsComplete"));
            }
            other => panic!("expected the objective chain, got {other:?}"),
        }
        assert_eq!(
            r.file.objective_refs.len(),
            2,
            "both uses of the alias are references"
        );
    }

    #[test]
    fn locals_may_sit_anywhere_and_rebind() {
        let src = "When(Team.Player.Has(UnitDef(\"armpw\"), 1)).Do(Objective(\"a\").Complete())\nlocal n = 3\nn = 4\nWhen(Team.Player.Has(UnitDef(\"armpw\"), n)).Do(Objective(\"b\").Complete())\n";
        let r = recognize_file("t/triggers/a.lua", src).unwrap();
        assert!(findings(&r).is_empty(), "{:?}", findings(&r));
        let second = &r.file.groups[0].triggers[1].steps[0];
        let Value::Verb { calls, .. } = &second.args[0] else {
            panic!()
        };
        assert!(matches!(&calls[0].args[1], Value::Number { value, .. } if *value == 4.0));
    }

    #[test]
    fn a_definition_file_exports_its_handles() {
        let src = "local hub = Spawn(UnitDef(\"corlab\"), \"gaia\").At(0.4, 0.4)\nlocal boss = Claim(UnitDef(\"armcom\"), \"enemy\").Named(\"armada_commander\").OrSpawnAt(0.8, 0.8)\nreturn { hub = hub, boss = boss }\n";
        let r = recognize_file("t/units.lua", src).unwrap();
        assert!(findings(&r).is_empty(), "{:?}", findings(&r));
        let exports: Vec<(&str, &str)> = r
            .file
            .unit_exports
            .iter()
            .map(|e| (e.key.as_str(), e.name.as_str()))
            .collect();
        assert_eq!(exports, vec![("hub", "hub"), ("boss", "armada_commander")]);
        assert_eq!(
            r.file.unit_exports[0].class.as_deref(),
            Some("MissionSpawnChain")
        );
        assert_eq!(
            r.file.unit_exports[1].class.as_deref(),
            Some("MissionClaimChain")
        );
        // the key names the unnamed handle, so it counts as a declared name
        assert!(r.file.unit_defs.contains(&"hub".to_string()));
        assert!(r.file.unit_defs.contains(&"armada_commander".to_string()));
    }

    #[test]
    fn export_references_read_as_the_surface_they_stand_for() {
        let src = "local Units = VFS.Include(\"modules/missions/t/units.lua\")\nlocal O = VFS.Include(\"modules/missions/t/objectives.lua\")\nWhen(Units.hub.IsSpotted(Team.Player)).Do(Combat.Protect(Units.hub))\nWhen(O.relieve.IsComplete()).Do(MatchFlow.Victory(Team.Player))\n";
        let r = recognize_file("t/triggers/a.lua", src).unwrap();
        assert!(findings(&r).is_empty(), "{:?}", findings(&r));
        let refs: Vec<(&str, &str)> = r
            .file
            .export_refs
            .iter()
            .map(|x| (x.file.rsplit('/').next().unwrap(), x.key.as_str()))
            .collect();
        assert_eq!(
            refs,
            vec![
                ("units.lua", "hub"),
                ("units.lua", "hub"),
                ("objectives.lua", "relieve")
            ]
        );
    }

    #[test]
    fn an_objectives_file_exports_ids_by_key() {
        let src = "local relieve = Objective(\"relieve_the_outpost\").Title(\"Relieve\")\nreturn { relieve = relieve, enough = 3 }\n";
        let r = recognize_file("t/objectives.lua", src).unwrap();
        assert_eq!(r.file.objective_exports.len(), 1);
        assert_eq!(r.file.objective_exports[0].name, "relieve_the_outpost");
        assert_eq!(
            r.file.objective_exports[0].class.as_deref(),
            Some("MissionObjectiveDeclaration")
        );
        // Anything exports: a plain value is referenced by key like a handle,
        // it just has no verbs of its own.
        assert!(findings(&r).is_empty(), "{:?}", findings(&r));
        let keys: Vec<&str> = r.file.exports.iter().map(|e| e.key.as_str()).collect();
        assert_eq!(keys, vec!["relieve", "enough"]);
        assert!(r.file.exports[1].class.is_none());
    }

    #[test]
    fn control_flow_and_unknown_globals_stay_out() {
        let src = "if true then end\nx = 1\n";
        let r = recognize_file("t/triggers/a.lua", src).unwrap();
        assert_eq!(r.file.opaque.len(), 2);
        assert!(findings(&r)[1].contains("no local declared"));
    }
}
