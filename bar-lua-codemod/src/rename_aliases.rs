use full_moon::ast::*;
use full_moon::tokenizer::*;
use full_moon::visitors::VisitorMut;
use std::collections::HashMap;

pub struct RenameAliases {
    aliases: HashMap<String, String>,
    pub conversions: usize,
}

impl RenameAliases {
    pub fn new(aliases: &[(&str, &str)]) -> Self {
        Self {
            aliases: aliases
                .iter()
                .map(|(old, new)| (old.to_string(), new.to_string()))
                .collect(),
            conversions: 0,
        }
    }

    /// If prefix is "Spring" and first suffix is `.OldName` where OldName is
    /// in our alias map, rewrite the suffix to use the canonical name.
    fn try_rewrite(&mut self, prefix: &Prefix, suffixes: &[Suffix]) -> Option<Vec<Suffix>> {
        let Prefix::Name(token_ref) = prefix else {
            return None;
        };
        if token_ref.token().to_string() != "Spring" {
            return None;
        }
        let Some(Suffix::Index(Index::Dot { dot, name })) = suffixes.first() else {
            return None;
        };
        let method_name = name.token().to_string();
        let canonical = self.aliases.get(&method_name)?;
        self.conversions += 1;
        let new_name = TokenReference::new(
            name.leading_trivia().cloned().collect(),
            Token::new(TokenType::Identifier {
                identifier: canonical.as_str().into(),
            }),
            name.trailing_trivia().cloned().collect(),
        );
        let mut new_suffixes = vec![Suffix::Index(Index::Dot {
            dot: dot.clone(),
            name: new_name,
        })];
        new_suffixes.extend(suffixes[1..].iter().cloned());
        Some(new_suffixes)
    }
}

impl VisitorMut for RenameAliases {
    fn visit_function_call(&mut self, call: FunctionCall) -> FunctionCall {
        let suffixes: Vec<Suffix> = call.suffixes().cloned().collect();
        if let Some(new_suffixes) = self.try_rewrite(call.prefix(), &suffixes) {
            call.with_suffixes(new_suffixes)
        } else {
            call
        }
    }

    fn visit_var(&mut self, var: Var) -> Var {
        match var {
            Var::Expression(var_expr) => {
                let suffixes: Vec<Suffix> = var_expr.suffixes().cloned().collect();
                if let Some(new_suffixes) = self.try_rewrite(var_expr.prefix(), &suffixes) {
                    Var::Expression(Box::new(var_expr.with_suffixes(new_suffixes)))
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

    const ALIASES: &[(&str, &str)] = &[
        ("GetMyTeamID", "GetLocalTeamID"),
        ("GetMyAllyTeamID", "GetLocalAllyTeamID"),
        ("GetMyPlayerID", "GetLocalPlayerID"),
    ];

    fn transform(input: &str) -> (String, usize) {
        let ast = parse(input).expect("parse failed");
        let mut visitor = RenameAliases::new(ALIASES);
        let ast = visitor.visit_ast(ast);
        (ast.to_string(), visitor.conversions)
    }

    #[test]
    fn renames_call() {
        let (out, n) = transform("local t = Spring.GetMyTeamID()");
        assert_eq!(out, "local t = Spring.GetLocalTeamID()");
        assert_eq!(n, 1);
    }

    #[test]
    fn renames_var_reference() {
        let (out, n) = transform("local fn = Spring.GetMyAllyTeamID");
        assert_eq!(out, "local fn = Spring.GetLocalAllyTeamID");
        assert_eq!(n, 1);
    }

    #[test]
    fn non_alias_unchanged() {
        let (out, n) = transform("Spring.GetGameFrame()");
        assert_eq!(out, "Spring.GetGameFrame()");
        assert_eq!(n, 0);
    }

    #[test]
    fn non_spring_unchanged() {
        let (out, n) = transform("Other.GetMyTeamID()");
        assert_eq!(out, "Other.GetMyTeamID()");
        assert_eq!(n, 0);
    }

    #[test]
    fn preserves_trivia() {
        let (out, n) = transform("  local id = Spring.GetMyPlayerID() -- get player");
        assert_eq!(out, "  local id = Spring.GetLocalPlayerID() -- get player");
        assert_eq!(n, 1);
    }

    #[test]
    fn multiple_in_one_file() {
        let input = "local a = Spring.GetMyTeamID()\nlocal b = Spring.GetMyAllyTeamID()";
        let (out, n) = transform(input);
        assert!(out.contains("Spring.GetLocalTeamID()"));
        assert!(out.contains("Spring.GetLocalAllyTeamID()"));
        assert_eq!(n, 2);
    }
}
