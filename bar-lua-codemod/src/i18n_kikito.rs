use full_moon::ast::punctuated::{Pair, Punctuated};
use full_moon::ast::*;
use full_moon::tokenizer::*;
use full_moon::visitors::VisitorMut;

const UNIT_NAME_PREFIX: &str = "units.names.";
const SERVICE_CODE: &str = include_str!("i18n_service.lua");

// ---------------------------------------------------------------------------
// Part A: Rewrite modules/i18n/i18n.lua
// ---------------------------------------------------------------------------

pub fn rewrite_wrapper(content: &str) -> Result<String, String> {
    full_moon::parse(content).map_err(|e| format!("original parse error: {e:?}"))?;

    let mut output = String::new();
    let mut injected = false;

    for line in content.lines() {
        let trimmed = line.trim();

        if trimmed.starts_with("local currentDirectory") {
            continue;
        }
        if trimmed.starts_with("I18N_PATH") {
            continue;
        }
        if trimmed.contains("VFS.Include(I18N_PATH") {
            output.push_str(SERVICE_CODE);
            output.push('\n');
            injected = true;
            continue;
        }

        output.push_str(line);
        output.push('\n');
    }

    if !injected {
        return Err("could not find VFS.Include(I18N_PATH ...) line to replace".into());
    }

    full_moon::parse(&output).map_err(|e| format!("transformed wrapper parse error: {e:?}"))?;
    Ok(output)
}

// ---------------------------------------------------------------------------
// Part B: Transform call sites — I18N('units.names.' .. X) → I18N.unitName(X)
// ---------------------------------------------------------------------------

fn string_content(expr: &Expression) -> Option<String> {
    if let Expression::String(token_ref) = expr {
        let s = token_ref.token().to_string();
        if (s.starts_with('"') && s.ends_with('"')) || (s.starts_with('\'') && s.ends_with('\''))
        {
            return Some(s[1..s.len() - 1].to_string());
        }
    }
    None
}

pub struct I18nCallSites {
    pub conversions: usize,
}

impl I18nCallSites {
    pub fn new() -> Self {
        Self { conversions: 0 }
    }
}

impl VisitorMut for I18nCallSites {
    fn visit_function_call(&mut self, call: FunctionCall) -> FunctionCall {
        let suffixes: Vec<Suffix> = call.suffixes().cloned().collect();

        let prefix_name = match call.prefix() {
            Prefix::Name(token_ref) => token_ref.token().to_string(),
            _ => return call,
        };

        // Identify the call-suffix index for a direct i18n translate invocation.
        // Spring.I18N(...)  → suffixes[0]=.I18N  suffixes[1]=(...)  → call_idx=1
        // I18N(...)         → suffixes[0]=(...)                     → call_idx=0
        let call_idx;
        if prefix_name == "Spring" {
            if suffixes.len() < 2 {
                return call;
            }
            match &suffixes[0] {
                Suffix::Index(Index::Dot { name, .. })
                    if name.token().to_string() == "I18N" => {}
                _ => return call,
            }
            if !matches!(&suffixes[1], Suffix::Call(Call::AnonymousCall(_))) {
                return call;
            }
            call_idx = 1;
        } else if prefix_name == "I18N" {
            if suffixes.is_empty() {
                return call;
            }
            if !matches!(&suffixes[0], Suffix::Call(Call::AnonymousCall(_))) {
                return call;
            }
            call_idx = 0;
        } else {
            return call;
        }

        let Suffix::Call(Call::AnonymousCall(FunctionArgs::Parentheses {
            parentheses,
            arguments,
        })) = &suffixes[call_idx]
        else {
            return call;
        };

        let Some(first_arg) = arguments.iter().next() else {
            return call;
        };

        // Match 'units.names.' .. X  (concatenation)
        let new_arg =
            if let Expression::BinaryOperator { lhs, binop, rhs } = first_arg {
                if !matches!(binop, BinOp::TwoDots(_)) {
                    return call;
                }
                match string_content(lhs) {
                    Some(ref s) if s == UNIT_NAME_PREFIX => Some((**rhs).clone()),
                    _ => return call,
                }
            // Match 'units.names.someLiteral' (full string literal)
            } else if let Some(content) = string_content(first_arg) {
                if content.starts_with(UNIT_NAME_PREFIX) && content.len() > UNIT_NAME_PREFIX.len()
                {
                    let remaining = &content[UNIT_NAME_PREFIX.len()..];
                    let token_str = if let Expression::String(tr) = first_arg {
                        tr.token().to_string()
                    } else {
                        return call;
                    };
                    let quote_type = if token_str.starts_with('"') {
                        StringLiteralQuoteType::Double
                    } else {
                        StringLiteralQuoteType::Single
                    };
                    Some(Expression::String(TokenReference::new(
                        vec![],
                        Token::new(TokenType::StringLiteral {
                            literal: remaining.into(),
                            multi_line_depth: 0,
                            quote_type,
                        }),
                        vec![],
                    )))
                } else {
                    return call;
                }
            } else {
                return call;
            };

        let Some(new_arg) = new_arg else {
            return call;
        };

        self.conversions += 1;

        let mut new_suffixes = suffixes[..call_idx].to_vec();

        new_suffixes.push(Suffix::Index(Index::Dot {
            dot: TokenReference::new(
                vec![],
                Token::new(TokenType::Symbol {
                    symbol: Symbol::Dot,
                }),
                vec![],
            ),
            name: TokenReference::new(
                vec![],
                Token::new(TokenType::Identifier {
                    identifier: "unitName".into(),
                }),
                vec![],
            ),
        }));

        let mut new_args = Punctuated::new();
        new_args.push(Pair::End(new_arg));

        new_suffixes.push(Suffix::Call(Call::AnonymousCall(
            FunctionArgs::Parentheses {
                parentheses: parentheses.clone(),
                arguments: new_args,
            },
        )));

        if call_idx + 1 < suffixes.len() {
            new_suffixes.extend_from_slice(&suffixes[call_idx + 1..]);
        }

        call.with_suffixes(new_suffixes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use full_moon::{parse, visitors::VisitorMut};

    fn transform(input: &str) -> (String, usize) {
        let ast = parse(input).expect("parse failed");
        let mut visitor = I18nCallSites::new();
        let ast = visitor.visit_ast(ast);
        (ast.to_string(), visitor.conversions)
    }

    #[test]
    fn spring_i18n_concat() {
        let (out, n) = transform("local x = Spring.I18N('units.names.' .. name)");
        assert_eq!(out, "local x = Spring.I18N.unitName(name)");
        assert_eq!(n, 1);
    }

    #[test]
    fn bare_i18n_concat() {
        let (out, n) = transform("local x = I18N('units.names.' .. name)");
        assert_eq!(out, "local x = I18N.unitName(name)");
        assert_eq!(n, 1);
    }

    #[test]
    fn string_literal_key() {
        let (out, n) = transform("local x = Spring.I18N('units.names.armcom')");
        assert_eq!(out, "local x = Spring.I18N.unitName('armcom')");
        assert_eq!(n, 1);
    }

    #[test]
    fn double_quoted() {
        let (out, n) = transform(r#"local x = Spring.I18N("units.names." .. name)"#);
        assert_eq!(out, r#"local x = Spring.I18N.unitName(name)"#);
        assert_eq!(n, 1);
    }

    #[test]
    fn non_unit_name_key_unchanged() {
        let (out, n) = transform("local x = Spring.I18N('units.descriptions.' .. name)");
        assert_eq!(out, "local x = Spring.I18N('units.descriptions.' .. name)");
        assert_eq!(n, 0);
    }

    #[test]
    fn i18n_set_unchanged() {
        let (out, n) =
            transform("Spring.I18N.set('en.units.names.' .. name, humanName)");
        assert_eq!(
            out,
            "Spring.I18N.set('en.units.names.' .. name, humanName)"
        );
        assert_eq!(n, 0);
    }

    #[test]
    fn non_i18n_unchanged() {
        let (out, n) = transform("Other('units.names.' .. name)");
        assert_eq!(out, "Other('units.names.' .. name)");
        assert_eq!(n, 0);
    }

    #[test]
    fn multiple_conversions() {
        let input = "Spring.I18N('units.names.' .. a)\nSpring.I18N('units.names.' .. b)";
        let (out, n) = transform(input);
        assert!(out.contains("Spring.I18N.unitName(a)"));
        assert!(out.contains("Spring.I18N.unitName(b)"));
        assert_eq!(n, 2);
    }

    #[test]
    fn preserves_trivia() {
        let (out, n) = transform("  Spring.I18N('units.names.' .. x) -- name");
        assert_eq!(out, "  Spring.I18N.unitName(x) -- name");
        assert_eq!(n, 1);
    }

    #[test]
    fn concatenation_in_larger_expr() {
        let (out, n) = transform(
            r#"local s = "Scav " .. Spring.I18N('units.names.' .. name)"#,
        );
        assert_eq!(out, r#"local s = "Scav " .. Spring.I18N.unitName(name)"#);
        assert_eq!(n, 1);
    }

    #[test]
    fn wrapper_rewrite_basic() {
        let input = r#"local currentDirectory = "modules/i18n/"
I18N_PATH = currentDirectory .. "i18nlib/i18n/"
local i18n = VFS.Include(I18N_PATH .. "init.lua", nil, VFS.ZIP)

local asianFont = 'fallbacks/SourceHanSans-Regular.ttc'
return i18n
"#;
        let result = rewrite_wrapper(input).expect("rewrite failed");
        assert!(result.contains("_findI18nBase"));
        assert!(result.contains("local i18n = require(\"i18n\")"));
        assert!(result.contains("require = _origRequire"));
        assert!(!result.contains("I18N_PATH"));
        assert!(!result.contains("currentDirectory"));
        assert!(result.contains("i18n.loadFile"));
        assert!(result.contains("i18n.unitName"));
        assert!(result.contains("_translate"));
        assert!(result.contains("asianFont"));
    }
}
