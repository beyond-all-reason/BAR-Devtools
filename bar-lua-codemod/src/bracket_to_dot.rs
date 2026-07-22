use crate::cst::{bracket_span, bracket_string_key, quoted_content};
use crate::edit::{self, Edit};
use emmylua_parser::{LuaAstNode, LuaIndexExpr, LuaSyntaxTree, LuaTableField};

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

pub struct BracketToDot {
    pub index_conversions: usize,
    pub field_conversions: usize,
    pub skipped_reserved: usize,
}

impl BracketToDot {
    pub fn new() -> Self {
        Self {
            index_conversions: 0,
            field_conversions: 0,
            skipped_reserved: 0,
        }
    }

    pub fn rewrite(&mut self, source: &str, tree: &LuaSyntaxTree) -> String {
        let mut edits: Vec<Edit> = Vec::new();
        for node in tree.get_chunk_node().syntax().descendants() {
            if let Some(index) = LuaIndexExpr::cast(node.clone()) {
                self.index_expr(source, &index, &mut edits);
            } else if let Some(field) = LuaTableField::cast(node) {
                self.table_field(&field, &mut edits);
            }
        }
        edit::apply(source, edits)
    }

    /// x["y"] -> x.y; a space is injected when `]` abuts a word character
    /// (]keyword is fine, .identifierkeyword merges).
    fn index_expr(&mut self, source: &str, index: &LuaIndexExpr, edits: &mut Vec<Edit>) {
        let Some(token) = bracket_string_key(index.syntax()) else {
            return;
        };
        let Some(name) = quoted_content(&token) else {
            return;
        };
        if is_convertible_identifier(&name) {
            let Some((start, end)) = bracket_span(index.syntax()) else {
                return;
            };
            self.index_conversions += 1;
            let mut text = format!(".{name}");
            let next_is_word = source
                .as_bytes()
                .get(end)
                .map(|&b| b.is_ascii_alphanumeric() || b == b'_')
                .unwrap_or(false);
            if next_is_word {
                text.push(' ');
            }
            edits.push(Edit { start, end, text });
        } else if LUA_RESERVED.contains(&name.as_str()) {
            self.skipped_reserved += 1;
        }
    }

    /// ["y"] = v -> y = v (table constructor fields).
    fn table_field(&mut self, field: &LuaTableField, edits: &mut Vec<Edit>) {
        if !field.is_assign_field() {
            return;
        }
        let Some(token) = bracket_string_key(field.syntax()) else {
            return;
        };
        let Some(name) = quoted_content(&token) else {
            return;
        };
        if is_convertible_identifier(&name) {
            let Some((start, end)) = bracket_span(field.syntax()) else {
                return;
            };
            self.field_conversions += 1;
            edits.push(Edit { start, end, text: name });
        } else if LUA_RESERVED.contains(&name.as_str()) {
            self.skipped_reserved += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cst::parse;

    fn transform(input: &str) -> (String, usize, usize) {
        let tree = parse(input).expect("parse failed");
        let mut visitor = BracketToDot::new();
        let out = visitor.rewrite(input, &tree);
        (out, visitor.index_conversions, visitor.field_conversions)
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

    #[test]
    fn escape_in_string_skipped() {
        let (out, idx, _) = transform(r#"local x = t["\097bc"]"#);
        assert_eq!(out, r#"local x = t["\097bc"]"#);
        assert_eq!(idx, 0);
    }

    #[test]
    fn inner_bracket_trivia_dropped() {
        let (out, idx, _) = transform(r#"local x = t[ "foo" ]"#);
        assert_eq!(out, "local x = t.foo");
        assert_eq!(idx, 1);
    }
}
