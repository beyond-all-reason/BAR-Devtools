use full_moon::ast::*;
use full_moon::tokenizer::*;
use full_moon::visitors::VisitorMut;

const LUA_RESERVED: &[&str] = &[
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
];

fn is_convertible_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_') && !LUA_RESERVED.contains(&s)
}

fn string_content(expr: &Expression) -> Option<String> {
    if let Expression::String(token_ref) = expr {
        let s = token_ref.token().to_string();
        if (s.starts_with('"') && s.ends_with('"')) || (s.starts_with('\'') && s.ends_with('\'')) {
            return Some(s[1..s.len() - 1].to_string());
        }
    }
    None
}

pub struct BracketToDot {
    pub index_conversions: usize,
    pub field_conversions: usize,
    pub skipped_reserved: usize,
    source: Vec<u8>,
}

impl BracketToDot {
    pub fn new(source: &str) -> Self {
        Self {
            index_conversions: 0,
            field_conversions: 0,
            skipped_reserved: 0,
            source: source.as_bytes().to_vec(),
        }
    }

    fn next_source_byte_is_word_char(&self, close: &TokenReference) -> bool {
        let byte_offset = close.token().end_position().bytes();
        self.source
            .get(byte_offset)
            .map(|&b| b.is_ascii_alphanumeric() || b == b'_')
            .unwrap_or(false)
    }
}

impl VisitorMut for BracketToDot {
    fn visit_index(&mut self, index: Index) -> Index {
        if let Index::Brackets {
            ref brackets,
            ref expression,
        } = index
        {
            if let Some(name) = string_content(expression) {
                if is_convertible_identifier(&name) {
                    self.index_conversions += 1;
                    let (open, close) = brackets.tokens();
                    let leading: Vec<Token> = open.leading_trivia().cloned().collect();
                    let mut trailing: Vec<Token> = close.trailing_trivia().cloned().collect();
                    // ]keyword is fine (] is non-alpha), but .identifierkeyword merges.
                    // Only inject a space when the next source char is a word character.
                    if trailing.is_empty() && self.next_source_byte_is_word_char(close) {
                        trailing.push(Token::new(TokenType::Whitespace {
                            characters: " ".into(),
                        }));
                    }
                    return Index::Dot {
                        dot: TokenReference::new(
                            leading,
                            Token::new(TokenType::Symbol {
                                symbol: Symbol::Dot,
                            }),
                            vec![],
                        ),
                        name: TokenReference::new(
                            vec![],
                            Token::new(TokenType::Identifier {
                                identifier: name.into(),
                            }),
                            trailing,
                        ),
                    };
                } else if LUA_RESERVED.contains(&name.as_str()) {
                    self.skipped_reserved += 1;
                }
            }
        }
        index
    }

    fn visit_field(&mut self, field: Field) -> Field {
        if let Field::ExpressionKey {
            ref brackets,
            ref key,
            ref equal,
            ref value,
            ..
        } = field
        {
            if let Some(name) = string_content(key) {
                if is_convertible_identifier(&name) {
                    self.field_conversions += 1;
                    let (open, close) = brackets.tokens();
                    let leading: Vec<Token> = open.leading_trivia().cloned().collect();
                    let trailing: Vec<Token> = close.trailing_trivia().cloned().collect();
                    return Field::NameKey {
                        key: TokenReference::new(
                            leading,
                            Token::new(TokenType::Identifier {
                                identifier: name.into(),
                            }),
                            trailing,
                        ),
                        equal: equal.clone(),
                        value: value.clone(),
                    };
                } else if LUA_RESERVED.contains(&name.as_str()) {
                    self.skipped_reserved += 1;
                }
            }
        }
        field
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use full_moon::{parse, visitors::VisitorMut};

    fn transform(input: &str) -> (String, usize, usize) {
        let ast = parse(input).expect("parse failed");
        let mut visitor = BracketToDot::new(input);
        let ast = visitor.visit_ast(ast);
        (
            ast.to_string(),
            visitor.index_conversions,
            visitor.field_conversions,
        )
    }

    #[test]
    fn index_simple() {
        let (out, idx, fld) = transform(r#"local x = t["foo"]"#);
        assert_eq!(out, "local x = t.foo");
        assert_eq!(idx, 1);
        assert_eq!(fld, 0);
    }

    #[test]
    fn index_single_quotes() {
        let (out, idx, _) = transform("local x = t['bar']");
        assert_eq!(out, "local x = t.bar");
        assert_eq!(idx, 1);
    }

    #[test]
    fn index_chained() {
        let (out, idx, _) = transform(r#"local x = t["a"]["b"]"#);
        assert_eq!(out, "local x = t.a.b");
        assert_eq!(idx, 2);
    }

    #[test]
    fn index_reserved_word_skipped() {
        let (out, _, _) = transform(r#"local x = t["end"]"#);
        assert_eq!(out, r#"local x = t["end"]"#);
    }

    #[test]
    fn index_numeric_key_skipped() {
        let (out, idx, _) = transform(r#"local x = t["123"]"#);
        assert_eq!(out, r#"local x = t["123"]"#);
        assert_eq!(idx, 0);
    }

    #[test]
    fn index_special_chars_skipped() {
        let (out, idx, _) = transform(r#"local x = t["foo-bar"]"#);
        assert_eq!(out, r#"local x = t["foo-bar"]"#);
        assert_eq!(idx, 0);
    }

    #[test]
    fn field_simple() {
        let (out, idx, fld) = transform(r#"local t = { ["foo"] = 1 }"#);
        assert_eq!(out, "local t = { foo = 1 }");
        assert_eq!(idx, 0);
        assert_eq!(fld, 1);
    }

    #[test]
    fn field_reserved_word_skipped() {
        let (out, _, fld) = transform(r#"local t = { ["end"] = 1 }"#);
        assert_eq!(out, r#"local t = { ["end"] = 1 }"#);
        assert_eq!(fld, 0);
    }

    #[test]
    fn mixed_conversions() {
        let (out, idx, fld) = transform(r#"t["x"] = { ["y"] = 1 }"#);
        assert_eq!(out, "t.x = { y = 1 }");
        assert_eq!(idx, 1);
        assert_eq!(fld, 1);
    }

    #[test]
    fn underscore_identifier() {
        let (out, idx, _) = transform(r#"local x = t["_private"]"#);
        assert_eq!(out, "local x = t._private");
        assert_eq!(idx, 1);
    }

    #[test]
    fn no_changes() {
        let (out, idx, fld) = transform("local x = t[42]");
        assert_eq!(out, "local x = t[42]");
        assert_eq!(idx, 0);
        assert_eq!(fld, 0);
    }

    #[test]
    fn bracket_then_dot_access() {
        let (out, idx, _) = transform(r#"local x = cmd[1]["options"].ctrl"#);
        assert_eq!(out, "local x = cmd[1].options.ctrl");
        assert_eq!(idx, 1);
    }

    #[test]
    fn bracket_to_dot_then_dot_access() {
        let (out, idx, _) = transform(r#"local x = WeaponDefNames["lightning_chain"].id"#);
        assert_eq!(out, "local x = WeaponDefNames.lightning_chain.id");
        assert_eq!(idx, 1);
    }

    #[test]
    fn no_merge_with_following_keyword() {
        let (out, idx, _) = transform("if force and WG['guishader']then end");
        assert!(out.contains("WG.guishader then"), "got: {out}");
        assert_eq!(idx, 1);
    }

    #[test]
    fn no_merge_with_following_identifier() {
        let (out, idx, _) = transform("local x = t['key']or false");
        assert!(out.contains("t.key or"), "got: {out}");
        assert_eq!(idx, 1);
    }
}
