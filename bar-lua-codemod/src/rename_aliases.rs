use crate::cst::is_func_stat_name;
use crate::edit::{self, Edit};
use emmylua_parser::{
    LuaAstNode, LuaAstToken, LuaExpr, LuaIndexExpr, LuaIndexKey, LuaSyntaxTree,
};
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

    /// Rewrite `Spring.OldName` to the canonical name wherever the prefix is
    /// the bare `Spring` global.
    pub fn rewrite(&mut self, source: &str, tree: &LuaSyntaxTree) -> String {
        let mut edits: Vec<Edit> = Vec::new();
        for node in tree.get_chunk_node().syntax().descendants() {
            let Some(index) = LuaIndexExpr::cast(node) else {
                continue;
            };
            if is_func_stat_name(index.syntax()) {
                continue;
            }
            let Some(LuaExpr::NameExpr(prefix)) = index.get_prefix_expr() else {
                continue;
            };
            if prefix.get_name_text().as_deref() != Some("Spring") {
                continue;
            }
            let Some(LuaIndexKey::Name(name)) = index.get_index_key() else {
                continue;
            };
            let Some(canonical) = self.aliases.get(name.get_name_text()) else {
                continue;
            };
            self.conversions += 1;
            let range = name.get_range();
            edits.push(Edit {
                start: usize::from(range.start()),
                end: usize::from(range.end()),
                text: canonical.clone(),
            });
        }
        edit::apply(source, edits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cst::parse;

    const ALIASES: &[(&str, &str)] = &[
        ("GetMyTeamID", "GetLocalTeamID"),
        ("GetMyAllyTeamID", "GetLocalAllyTeamID"),
        ("GetMyPlayerID", "GetLocalPlayerID"),
    ];

    fn transform(input: &str) -> (String, usize) {
        let tree = parse(input).expect("parse failed");
        let mut visitor = RenameAliases::new(ALIASES);
        let out = visitor.rewrite(input, &tree);
        (out, visitor.conversions)
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

    #[test]
    fn bracket_access_unchanged() {
        let (out, n) = transform(r#"local f = Spring["GetMyTeamID"]"#);
        assert_eq!(out, r#"local f = Spring["GetMyTeamID"]"#);
        assert_eq!(n, 0);
    }
}
