use emmylua_parser::{
    LuaAstNode, LuaAstToken, LuaLanguageLevel, LuaLiteralExpr, LuaLiteralToken, LuaParseErrorKind,
    LuaParser, LuaStringToken, LuaSyntaxKind, LuaSyntaxNode, LuaSyntaxToken, LuaSyntaxTree,
    LuaTokenKind, ParserConfig,
};
use std::collections::HashMap;

/// Lua 5.1 (BAR's runtime level), doc-comment parsing off: comments are
/// trivia, as they were under full_moon.
pub fn parse(code: &str) -> Result<LuaSyntaxTree, String> {
    let config = ParserConfig::new(
        LuaLanguageLevel::Lua51,
        None,
        HashMap::new(),
        Default::default(),
        false,
    );
    let tree = LuaParser::parse(code, config);
    if tree.has_syntax_errors() {
        return Err(tree
            .get_errors()
            .iter()
            .filter(|e| e.kind == LuaParseErrorKind::SyntaxError)
            .map(|e| e.message.clone())
            .collect::<Vec<_>>()
            .join("; "));
    }
    Ok(tree)
}

/// Byte range from `[` through `]` of an index expr or table field node.
pub fn bracket_span(node: &LuaSyntaxNode) -> Option<(usize, usize)> {
    let mut start = None;
    for child in node.children_with_tokens() {
        let Some(token) = child.as_token() else {
            continue;
        };
        if token.kind() == LuaTokenKind::TkLeftBracket.into() && start.is_none() {
            start = Some(usize::from(token.text_range().start()));
        } else if token.kind() == LuaTokenKind::TkRightBracket.into() {
            return Some((start?, usize::from(token.text_range().end())));
        }
    }
    None
}

fn is_trivia(token: &LuaSyntaxToken) -> bool {
    token.kind() == LuaTokenKind::TkWhitespace.into()
        || token.kind() == LuaTokenKind::TkEndOfLine.into()
        || token.kind() == LuaTokenKind::TkShortComment.into()
        || token.kind() == LuaTokenKind::TkLongComment.into()
}

/// The sole string-literal key of `[...]` in an index expr or table field,
/// tolerating trivia inside the brackets (which the upstream get_index_key
/// does not). None when the bracketed expression is anything else.
pub fn bracket_string_key(node: &LuaSyntaxNode) -> Option<LuaStringToken> {
    let mut in_brackets = false;
    let mut key: Option<LuaStringToken> = None;
    for child in node.children_with_tokens() {
        if !in_brackets {
            if child.as_token().map(|t| t.kind()) == Some(LuaTokenKind::TkLeftBracket.into()) {
                in_brackets = true;
            }
            continue;
        }
        if let Some(token) = child.as_token() {
            if token.kind() == LuaTokenKind::TkRightBracket.into() {
                return key;
            }
            if !is_trivia(token) {
                return None;
            }
        } else if let Some(inner) = child.into_node() {
            if key.is_some() {
                return None;
            }
            let literal = LuaLiteralExpr::cast(inner)?;
            match literal.get_literal()? {
                LuaLiteralToken::String(token) => key = Some(token),
                _ => return None,
            }
        }
    }
    None
}

/// Raw content of a single- or double-quoted string token; None for long
/// strings. No unescaping — parity with the raw-slice rule the conversions
/// were generated under.
pub fn quoted_content(token: &LuaStringToken) -> Option<String> {
    let s = token.get_text();
    if s.len() >= 2
        && ((s.starts_with('"') && s.ends_with('"')) || (s.starts_with('\'') && s.ends_with('\'')))
    {
        return Some(s[1..s.len() - 1].to_string());
    }
    None
}

/// True when the index chain is the name of `function a.b.c() end` —
/// a position full_moon's Var/FunctionCall visitors never rewrote.
pub fn is_func_stat_name(node: &LuaSyntaxNode) -> bool {
    let mut cur = node.clone();
    loop {
        let Some(parent) = cur.parent() else {
            return false;
        };
        let kind: LuaSyntaxKind = parent.kind().into();
        if kind == LuaSyntaxKind::IndexExpr {
            cur = parent;
            continue;
        }
        return kind == LuaSyntaxKind::FuncStat;
    }
}
