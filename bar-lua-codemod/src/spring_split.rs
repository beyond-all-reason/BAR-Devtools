use full_moon::ast::*;
use full_moon::tokenizer::*;
use full_moon::visitors::VisitorMut;
use std::collections::HashMap;
use std::path::Path;

/// Scan all .lua files under `library_dir` for method declarations and build
/// a mapping of method name -> target class (SpringSynced, SpringUnsynced,
/// or SpringShared).  First declaration wins if the same name appears in
/// multiple classes.
pub fn build_mapping(library_dir: &Path) -> HashMap<String, String> {
    let mut mapping = HashMap::new();
    let pattern = format!("{}/**/*.lua", library_dir.display());
    for entry in glob::glob(&pattern).expect("invalid glob pattern") {
        let path = match entry {
            Ok(p) => p,
            Err(_) => continue,
        };
        let content = match std::fs::read_to_string(&path) {
            Ok(c) => c,
            Err(_) => continue,
        };
        const CLASSES: &[&str] = &["SpringSynced", "SpringUnsynced", "SpringShared"];
        for line in content.lines() {
            let trimmed = line.trim();
            for &class in CLASSES {
                let fn_prefix = format!("function {}.", class);
                if let Some(rest) = trimmed.strip_prefix(&fn_prefix) {
                    if let Some(name) = rest.split('(').next() {
                        let name = name.trim();
                        if !name.is_empty() {
                            mapping.entry(name.to_string()).or_insert_with(|| class.to_string());
                        }
                    }
                    break;
                }
                let assign_prefix = format!("{}.", class);
                if let Some(rest) = trimmed.strip_prefix(&assign_prefix) {
                    if rest.contains(" = ") {
                        if let Some(name) = rest.split_whitespace().next() {
                            mapping.entry(name.to_string()).or_insert_with(|| class.to_string());
                        }
                    }
                    break;
                }
            }
        }
    }
    mapping
}

pub struct SpringSplit {
    mapping: HashMap<String, String>,
    pub conversions: usize,
    pub unmapped: usize,
    pub unmapped_names: HashMap<String, usize>,
}

impl SpringSplit {
    pub fn new(mapping: HashMap<String, String>) -> Self {
        Self {
            mapping,
            conversions: 0,
            unmapped: 0,
            unmapped_names: HashMap::new(),
        }
    }

    fn try_rewrite(&mut self, prefix: &Prefix, first_suffix: Option<&Suffix>) -> Option<Prefix> {
        let Prefix::Name(token_ref) = prefix else {
            return None;
        };
        if token_ref.token().to_string() != "Spring" {
            return None;
        }
        let Some(Suffix::Index(Index::Dot { name, .. })) = first_suffix else {
            return None;
        };
        let method_name = name.token().to_string();
        if let Some(class_name) = self.mapping.get(&method_name) {
            self.conversions += 1;
            let new_token = TokenReference::new(
                token_ref.leading_trivia().cloned().collect(),
                Token::new(TokenType::Identifier {
                    identifier: class_name.as_str().into(),
                }),
                token_ref.trailing_trivia().cloned().collect(),
            );
            Some(Prefix::Name(new_token))
        } else {
            self.unmapped += 1;
            *self.unmapped_names.entry(method_name).or_insert(0) += 1;
            None
        }
    }
}

impl VisitorMut for SpringSplit {
    fn visit_function_call(&mut self, call: FunctionCall) -> FunctionCall {
        let first = {
            let mut iter = call.suffixes();
            iter.next().cloned()
        };
        if let Some(new_prefix) = self.try_rewrite(call.prefix(), first.as_ref()) {
            call.with_prefix(new_prefix)
        } else {
            call
        }
    }

    fn visit_var(&mut self, var: Var) -> Var {
        match var {
            Var::Expression(var_expr) => {
                let first = {
                    let mut iter = var_expr.suffixes();
                    iter.next().cloned()
                };
                if let Some(new_prefix) = self.try_rewrite(var_expr.prefix(), first.as_ref()) {
                    Var::Expression(Box::new(var_expr.with_prefix(new_prefix)))
                } else {
                    Var::Expression(var_expr)
                }
            }
            other => other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use full_moon::{parse, visitors::VisitorMut};

    fn transform(input: &str, mapping: HashMap<String, String>) -> (String, usize) {
        let ast = parse(input).expect("parse failed");
        let mut visitor = SpringSplit::new(mapping);
        let ast = visitor.visit_ast(ast);
        (ast.to_string(), visitor.conversions)
    }

    fn shared(methods: &[&str]) -> HashMap<String, String> {
        methods
            .iter()
            .map(|m| (m.to_string(), "SpringShared".to_string()))
            .collect()
    }

    fn synced(methods: &[&str]) -> HashMap<String, String> {
        methods
            .iter()
            .map(|m| (m.to_string(), "SpringSynced".to_string()))
            .collect()
    }

    #[test]
    fn shared_call() {
        let (out, n) = transform("local x = Spring.GetGameFrame()", shared(&["GetGameFrame"]));
        assert_eq!(out, "local x = SpringShared.GetGameFrame()");
        assert_eq!(n, 1);
    }

    #[test]
    fn synced_call() {
        let (out, n) = transform(
            r#"Spring.CreateUnit("armcom", 0, 0, 0, 0, 0)"#,
            synced(&["CreateUnit"]),
        );
        assert_eq!(out, r#"SpringSynced.CreateUnit("armcom", 0, 0, 0, 0, 0)"#);
        assert_eq!(n, 1);
    }

    #[test]
    fn var_reference() {
        let (out, n) = transform("local fn = Spring.Echo", shared(&["Echo"]));
        assert_eq!(out, "local fn = SpringShared.Echo");
        assert_eq!(n, 1);
    }

    #[test]
    fn unmapped_unchanged() {
        let (out, n) = transform("Spring.UnknownMethod()", HashMap::new());
        assert_eq!(out, "Spring.UnknownMethod()");
        assert_eq!(n, 0);
    }

    #[test]
    fn not_spring_unchanged() {
        let (out, n) = transform("Other.GetGameFrame()", shared(&["GetGameFrame"]));
        assert_eq!(out, "Other.GetGameFrame()");
        assert_eq!(n, 0);
    }

    #[test]
    fn chained_access() {
        let (out, n) = transform(
            "Spring.MoveCtrl.SetLimits(unitID, 0, 0)",
            synced(&["MoveCtrl"]),
        );
        assert_eq!(out, "SpringSynced.MoveCtrl.SetLimits(unitID, 0, 0)");
        assert_eq!(n, 1);
    }

    #[test]
    fn multiple_in_one_file() {
        let mut mapping = HashMap::new();
        mapping.insert("Echo".to_string(), "SpringShared".to_string());
        mapping.insert("CreateUnit".to_string(), "SpringSynced".to_string());
        let (out, n) = transform(
            "Spring.Echo(\"hi\")\nSpring.CreateUnit(\"a\", 0, 0, 0, 0, 0)",
            mapping,
        );
        assert!(out.contains("SpringShared.Echo"));
        assert!(out.contains("SpringSynced.CreateUnit"));
        assert_eq!(n, 2);
    }

    fn unsynced(methods: &[&str]) -> HashMap<String, String> {
        methods
            .iter()
            .map(|m| (m.to_string(), "SpringUnsynced".to_string()))
            .collect()
    }

    #[test]
    fn unsynced_call() {
        let (out, n) = transform("Spring.SendCommands(cmd)", unsynced(&["SendCommands"]));
        assert_eq!(out, "SpringUnsynced.SendCommands(cmd)");
        assert_eq!(n, 1);
    }

    #[test]
    fn preserves_trivia() {
        let (out, n) = transform("  Spring.GetGameFrame() -- get frame", shared(&["GetGameFrame"]));
        assert_eq!(out, "  SpringShared.GetGameFrame() -- get frame");
        assert_eq!(n, 1);
    }
}
