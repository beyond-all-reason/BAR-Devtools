use full_moon::ast::*;
use full_moon::tokenizer::*;
use full_moon::visitors::VisitorMut;
use std::collections::HashSet;

pub struct DetachBarModules {
    modules: HashSet<String>,
    pub conversions: usize,
}

impl DetachBarModules {
    pub fn new(modules: &[&str]) -> Self {
        Self {
            modules: modules.iter().map(|s| s.to_string()).collect(),
            conversions: 0,
        }
    }

    /// Match `Spring.Module` (prefix = Spring) or `_G.Spring.Module`
    /// (prefix = _G, first suffix = .Spring). In both cases, rename the
    /// Spring segment to `BAR`, keeping the module name and everything after
    /// it (`Spring.I18N.t()` → `BAR.I18N.t()`).
    fn try_rewrite(
        &mut self,
        prefix: &Prefix,
        suffixes: &[Suffix],
    ) -> Option<(Prefix, Vec<Suffix>)> {
        let Prefix::Name(token_ref) = prefix else {
            return None;
        };
        let prefix_name = token_ref.token().to_string();

        if prefix_name == "Spring" {
            let Some(Suffix::Index(Index::Dot { name, .. })) = suffixes.first() else {
                return None;
            };
            if !self.modules.contains(&name.token().to_string()) {
                return None;
            }
            self.conversions += 1;
            let new_prefix = Prefix::Name(TokenReference::new(
                token_ref.leading_trivia().cloned().collect(),
                Token::new(TokenType::Identifier {
                    identifier: "BAR".into(),
                }),
                token_ref.trailing_trivia().cloned().collect(),
            ));
            return Some((new_prefix, suffixes.to_vec()));
        }

        if prefix_name == "_G" && suffixes.len() >= 2 {
            let Some(Suffix::Index(Index::Dot { dot, name: spring_name, .. })) = suffixes.first()
            else {
                return None;
            };
            if spring_name.token().to_string() != "Spring" {
                return None;
            }
            let Some(Suffix::Index(Index::Dot { name: module_name_tok, .. })) = suffixes.get(1)
            else {
                return None;
            };
            if !self.modules.contains(&module_name_tok.token().to_string()) {
                return None;
            }
            self.conversions += 1;
            let new_first = Suffix::Index(Index::Dot {
                dot: dot.clone(),
                name: TokenReference::new(
                    spring_name.leading_trivia().cloned().collect(),
                    Token::new(TokenType::Identifier {
                        identifier: "BAR".into(),
                    }),
                    spring_name.trailing_trivia().cloned().collect(),
                ),
            });
            let mut remaining = vec![new_first];
            remaining.extend_from_slice(&suffixes[1..]);
            return Some((prefix.clone(), remaining));
        }

        None
    }
}

impl VisitorMut for DetachBarModules {
    fn visit_function_call(&mut self, call: FunctionCall) -> FunctionCall {
        let suffixes: Vec<Suffix> = call.suffixes().cloned().collect();
        if let Some((new_prefix, remaining)) = self.try_rewrite(call.prefix(), &suffixes) {
            call.with_prefix(new_prefix)
                .with_suffixes(remaining)
        } else {
            call
        }
    }

    fn visit_var(&mut self, var: Var) -> Var {
        match var {
            Var::Expression(var_expr) => {
                let suffixes: Vec<Suffix> = var_expr.suffixes().cloned().collect();
                if let Some((new_prefix, remaining)) =
                    self.try_rewrite(var_expr.prefix(), &suffixes)
                {
                    Var::Expression(Box::new(
                        var_expr
                            .with_prefix(new_prefix)
                            .with_suffixes(remaining),
                    ))
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

    const MODULES: &[&str] = &["I18N", "Utilities", "Debug", "Lava"];

    fn transform(input: &str) -> (String, usize) {
        let ast = parse(input).expect("parse failed");
        let mut visitor = DetachBarModules::new(MODULES);
        let ast = visitor.visit_ast(ast);
        (ast.to_string(), visitor.conversions)
    }

    #[test]
    fn simple_call() {
        let (out, n) = transform("Spring.I18N.translate(key)");
        assert_eq!(out, "BAR.I18N.translate(key)");
        assert_eq!(n, 1);
    }

    #[test]
    fn method_access() {
        let (out, n) = transform("local x = Spring.Utilities.Round(1.5)");
        assert_eq!(out, "local x = BAR.Utilities.Round(1.5)");
        assert_eq!(n, 1);
    }

    #[test]
    fn var_reference() {
        let (out, n) = transform("local u = Spring.Utilities");
        assert_eq!(out, "local u = BAR.Utilities");
        assert_eq!(n, 1);
    }

    #[test]
    fn non_module_unchanged() {
        let (out, n) = transform("Spring.GetGameFrame()");
        assert_eq!(out, "Spring.GetGameFrame()");
        assert_eq!(n, 0);
    }

    #[test]
    fn non_spring_unchanged() {
        let (out, n) = transform("Other.I18N.translate(key)");
        assert_eq!(out, "Other.I18N.translate(key)");
        assert_eq!(n, 0);
    }

    #[test]
    fn preserves_trivia() {
        let (out, n) = transform("  Spring.Debug.log(msg) -- log it");
        assert_eq!(out, "  BAR.Debug.log(msg) -- log it");
        assert_eq!(n, 1);
    }

    #[test]
    fn assignment_declaration() {
        let (out, n) = transform("Spring.I18N = Spring.I18N or VFS.Include('i18n.lua')");
        assert_eq!(out, "BAR.I18N = BAR.I18N or VFS.Include('i18n.lua')");
        assert_eq!(n, 2);
    }

    #[test]
    fn multiple_in_one_file() {
        let (out, n) = transform("Spring.I18N.t('x')\nSpring.Lava.isActive()");
        assert!(out.contains("BAR.I18N.t('x')"));
        assert!(out.contains("BAR.Lava.isActive()"));
        assert_eq!(n, 2);
    }

    #[test]
    fn g_spring_module_assignment() {
        let (out, n) = transform("_G.Spring.Utilities = _G.Spring.Utilities or {}");
        assert_eq!(out, "_G.BAR.Utilities = _G.BAR.Utilities or {}");
        assert_eq!(n, 2);
    }

    #[test]
    fn g_spring_module_call() {
        let (out, n) = transform("_G.Spring.I18N('key')");
        assert_eq!(out, "_G.BAR.I18N('key')");
        assert_eq!(n, 1);
    }

    #[test]
    fn g_spring_non_module_unchanged() {
        let (out, n) = transform("_G.Spring.GetGameFrame()");
        assert_eq!(out, "_G.Spring.GetGameFrame()");
        assert_eq!(n, 0);
    }

    #[test]
    fn g_spring_deep_access() {
        let (out, n) = transform("_G.Spring.Utilities.Gametype.IsFFA()");
        assert_eq!(out, "_G.BAR.Utilities.Gametype.IsFFA()");
        assert_eq!(n, 1);
    }
}
