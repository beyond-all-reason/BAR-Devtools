//! The subset recognizer: classifies full_moon CST nodes into the decorated
//! mission AST. This walk IS the DSL grammar in the meaningful sense — the
//! single definition of what's form-editable — defined over a mature lossless
//! parse instead of a bespoke one. Check mode is the same walk with findings.

use crate::model::*;
use full_moon::ast;
use full_moon::node::Node;
use full_moon::tokenizer::{TokenReference, TokenType};

/// Chain verbs the framework grammar admits, in the only legal shape:
/// When first, Register last.
const CHAIN_VERBS: &[&str] = &["When", "AndWhen", "Debounce", "Once", "Do", "Register"];

pub struct Recognized {
    pub file: FileAst,
    pub findings: Vec<Finding>,
}

pub fn recognize_file(path: &str, source: &str) -> Result<Recognized, String> {
    let parsed = full_moon::parse(source).map_err(|errors| {
        errors
            .iter()
            .map(|e| e.to_string())
            .collect::<Vec<_>>()
            .join("; ")
    })?;

    let mut rec = Rec {
        path: path.to_string(),
        source,
        groups: vec![Group { label: None, triggers: Vec::new() }],
        opaque: Vec::new(),
        findings: Vec::new(),
        order: 0,
    };

    for stmt in parsed.nodes().stmts() {
        rec.statement(stmt);
    }

    // Drop an empty unlabeled leading section if grouped chains exist.
    let mut groups = rec.groups;
    if groups.len() > 1 && groups[0].label.is_none() && groups[0].triggers.is_empty() {
        groups.remove(0);
    }

    Ok(Recognized {
        file: FileAst { path: rec.path, groups, opaque: rec.opaque },
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

    fn statement(&mut self, stmt: &ast::Stmt) {
        let span = node_span(stmt);
        // Decorators ride the statement's leading trivia.
        let decorators = leading_decorators(stmt);
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

        match stmt {
            ast::Stmt::FunctionCall(call) => match self.trigger_chain(call, span, label) {
                Some(trigger) => {
                    self.groups.last_mut().unwrap().triggers.push(trigger)
                }
                None => {}
            },
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
        call: &ast::FunctionCall,
        span: Span,
        label: Option<String>,
    ) -> Option<Trigger> {
        let base = match call.prefix() {
            ast::Prefix::Name(token) => token.token().to_string(),
            _ => String::new(),
        };
        if base != "T" {
            self.mark_opaque(span, "statement is not a T.When trigger chain");
            return None;
        }

        let mut steps = Vec::new();
        let mut pending: Option<(String, Span)> = None;
        for suffix in call.suffixes() {
            match suffix {
                ast::Suffix::Index(ast::Index::Dot { name, .. }) => {
                    if pending.is_some() {
                        self.mark_opaque(span, "chain step without a call — every step needs parens");
                        return None;
                    }
                    pending = Some((name.token().to_string(), node_span(name)));
                }
                ast::Suffix::Call(ast::Call::AnonymousCall(args)) => {
                    let Some((verb, verb_span)) = pending.take() else {
                        self.mark_opaque(span, "call without a step name in chain");
                        return None;
                    };
                    let values = self.call_args(args);
                    steps.push(Step { verb, span: verb_span, args: values });
                }
                _ => {
                    self.mark_opaque(span, "unsupported call shape in chain (method call?)");
                    return None;
                }
            }
        }

        // Grammar checks (also the validator's rules).
        if steps.is_empty() || steps[0].verb != "When" {
            self.finding(span, "trigger chain must start with T.When(...)".into());
        }
        if steps.last().map(|s| s.verb.as_str()) != Some("Register") {
            self.finding(span, "trigger chain must end with .Register()".into());
        }
        for step in &steps {
            if !CHAIN_VERBS.contains(&step.verb.as_str()) {
                self.finding(
                    step.span,
                    format!("unknown chain verb '{}' (framework grammar: {})", step.verb, CHAIN_VERBS.join("/")),
                );
            }
        }

        self.order += 1;
        Some(Trigger {
            id: format!("{}:{}", self.path, self.order),
            span,
            label,
            steps,
        })
    }

    fn call_args(&mut self, args: &ast::FunctionArgs) -> Vec<Value> {
        match args {
            ast::FunctionArgs::Parentheses { arguments, .. } => {
                arguments.iter().map(|e| self.value(e)).collect()
            }
            _ => {
                let span = node_span(args);
                self.finding(span, "call arguments must use parentheses".into());
                vec![Value::Opaque { span, reason: "non-parenthesized call arguments".into() }]
            }
        }
    }

    /// Classify one expression into the subset's value vocabulary.
    fn value(&mut self, expr: &ast::Expression) -> Value {
        let span = node_span(expr);
        match expr {
            ast::Expression::Number(token) => {
                let value = token.token().to_string().trim().parse::<f64>().unwrap_or(f64::NAN);
                Value::Number { value, span }
            }
            ast::Expression::String(token) => Value::String {
                value: string_token_value(token),
                span,
            },
            ast::Expression::Symbol(token) => {
                let text = token.token().to_string();
                match text.trim() {
                    "true" => Value::Boolean { value: true, span },
                    "false" => Value::Boolean { value: false, span },
                    other => self.opaque_value(span, &format!("unsupported symbol '{other}'")),
                }
            }
            ast::Expression::TableConstructor(table) => self.table(table, span),
            ast::Expression::Var(var) => match var {
                ast::Var::Name(token) => Value::Name {
                    path: token.token().to_string(),
                    span,
                },
                ast::Var::Expression(var_expr) => self.dotted(var_expr.prefix(), var_expr.suffixes(), span),
                _ => self.opaque_value(span, "unsupported variable shape"),
            },
            ast::Expression::FunctionCall(call) => {
                self.verb_call(call.prefix(), call.suffixes(), span)
            }
            ast::Expression::Function(_) => self.opaque_value(
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

    /// A dotted reference with no call: Team.Player
    fn dotted<'a>(
        &mut self,
        prefix: &ast::Prefix,
        suffixes: impl Iterator<Item = &'a ast::Suffix>,
        span: Span,
    ) -> Value {
        let mut path = match prefix {
            ast::Prefix::Name(token) => token.token().to_string(),
            _ => return self.opaque_value(span, "computed base in reference"),
        };
        for suffix in suffixes {
            match suffix {
                ast::Suffix::Index(ast::Index::Dot { name, .. }) => {
                    path.push('.');
                    path.push_str(&name.token().to_string());
                }
                _ => return self.opaque_value(span, "computed index in reference"),
            }
        }
        Value::Name { path, span }
    }

    /// A verb expression: dotted path, then invocations, optionally chained.
    fn verb_call<'a>(
        &mut self,
        prefix: &ast::Prefix,
        suffixes: impl Iterator<Item = &'a ast::Suffix>,
        span: Span,
    ) -> Value {
        let mut path = match prefix {
            ast::Prefix::Name(token) => token.token().to_string(),
            _ => return self.opaque_value(span, "computed base in verb call"),
        };
        let mut calls: Vec<Invocation> = Vec::new();
        let mut chain_name: Option<String> = None;
        for suffix in suffixes {
            match suffix {
                ast::Suffix::Index(ast::Index::Dot { name, .. }) => {
                    let segment = name.token().to_string();
                    if calls.is_empty() {
                        path.push('.');
                        path.push_str(&segment);
                    } else if chain_name.is_none() {
                        chain_name = Some(segment);
                    } else {
                        return self.opaque_value(span, "nested index between chained calls");
                    }
                }
                ast::Suffix::Call(ast::Call::AnonymousCall(args)) => {
                    let arg_span = node_span(args);
                    let values = self.call_args(args);
                    calls.push(Invocation {
                        name: chain_name.take(),
                        args: values,
                        span: arg_span,
                    });
                }
                _ => return self.opaque_value(span, "method (colon) call in verb chain — the surface is dot-only"),
            }
        }
        if calls.is_empty() {
            return Value::Name { path, span };
        }
        Value::Verb { path, calls, span }
    }

    fn table(&mut self, table: &ast::TableConstructor, span: Span) -> Value {
        let mut fields = Vec::new();
        let mut index = 0usize;
        for field in table.fields() {
            match field {
                ast::Field::NameKey { key, value, .. } => {
                    let v = self.value(value);
                    fields.push(Field { key: key.token().to_string(), value: v });
                }
                ast::Field::NoKey(value) => {
                    index += 1;
                    let v = self.value(value);
                    fields.push(Field { key: index.to_string(), value: v });
                }
                _ => {
                    let fspan = node_span(field);
                    let v = self.opaque_value(fspan, "computed table key outside the subset");
                    fields.push(Field { key: String::from("?"), value: v });
                }
            }
        }
        Value::Table { fields, span }
    }
}

struct Decorator {
    name: String,
    args: Vec<String>,
}

/// Parse `---@group("Wave timing")` style decorators from a statement's
/// leading trivia. Comment decorators are grammar, not hints — but unknown
/// names are ignored here (forward compatibility); the vocabulary lives in
/// one place, the consumers of the AST.
fn leading_decorators(stmt: &ast::Stmt) -> Vec<Decorator> {
    let mut out = Vec::new();
    let Some(first_token) = stmt.tokens().next() else {
        return out;
    };
    for trivia in first_token.leading_trivia() {
        if let TokenType::SingleLineComment { comment } = trivia.token_type() {
            let text = comment.to_string();
            let Some(rest) = text.trim().strip_prefix("-@") else {
                continue; // `---@x` tokenizes as comment text `-@x`
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
    }
    out
}

fn string_token_value(token: &TokenReference) -> String {
    let text = token.token().to_string();
    let trimmed = text.trim();
    trimmed
        .trim_matches('"')
        .trim_matches('\'')
        .to_string()
}

fn node_span<N: Node>(node: &N) -> Span {
    let start = node
        .start_position()
        .map(|p| p.bytes())
        .unwrap_or(0);
    let end = node.end_position().map(|p| p.bytes()).unwrap_or(start);
    (start, end)
}
