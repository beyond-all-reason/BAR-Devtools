use crate::cst::is_func_stat_name;
use crate::edit::{self, Edit};
use emmylua_parser::{
    LuaAstNode, LuaAstToken, LuaExpr, LuaIndexExpr, LuaIndexKey, LuaSyntaxTree,
};
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

    /// Match `Spring.Module` or `_G.Spring.Module` and rename the Spring
    /// segment to `BAR`, keeping the module name and everything after it
    /// (`Spring.I18N.t()` -> `BAR.I18N.t()`).
    pub fn rewrite(&mut self, source: &str, tree: &LuaSyntaxTree) -> String {
        let mut edits: Vec<Edit> = Vec::new();
        for node in tree.get_chunk_node().syntax().descendants() {
            let Some(index) = LuaIndexExpr::cast(node) else {
                continue;
            };
            if is_func_stat_name(index.syntax()) {
                continue;
            }
            let Some(LuaIndexKey::Name(module)) = index.get_index_key() else {
                continue;
            };
            if !self.modules.contains(module.get_name_text()) {
                continue;
            }
            let spring_range = match index.get_prefix_expr() {
                Some(LuaExpr::NameExpr(prefix))
                    if prefix.get_name_text().as_deref() == Some("Spring") =>
                {
                    prefix.syntax().text_range()
                }
                Some(LuaExpr::IndexExpr(inner)) => {
                    let Some(LuaExpr::NameExpr(base)) = inner.get_prefix_expr() else {
                        continue;
                    };
                    if base.get_name_text().as_deref() != Some("_G") {
                        continue;
                    }
                    let Some(LuaIndexKey::Name(spring)) = inner.get_index_key() else {
                        continue;
                    };
                    if spring.get_name_text() != "Spring" {
                        continue;
                    }
                    spring.get_range()
                }
                _ => continue,
            };
            self.conversions += 1;
            edits.push(Edit {
                start: usize::from(spring_range.start()),
                end: usize::from(spring_range.end()),
                text: "BAR".to_string(),
            });
        }
        edit::apply(source, edits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cst::parse;

    const MODULES: &[&str] = &["I18N", "Utilities", "Debug", "Lava"];

    fn transform(input: &str) -> (String, usize) {
        let tree = parse(input).expect("parse failed");
        let mut visitor = DetachBarModules::new(MODULES);
        let out = visitor.rewrite(input, &tree);
        (out, visitor.conversions)
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

    #[test]
    fn function_definition_name_unchanged() {
        let (out, n) = transform("function Spring.Utilities.Round(x) return x end");
        assert_eq!(out, "function Spring.Utilities.Round(x) return x end");
        assert_eq!(n, 0);
    }
}
