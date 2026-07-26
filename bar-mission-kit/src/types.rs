//! The type surface: the kit's model of the mission DSL, derived from the
//! game's LuaCATS annotation files (modules/missions/types/dsl.lua and
//! types/missions.lua). The types are the grammar's source of truth:
//!
//!   - statement heads   = injected globals returning a chain class
//!   - chain verbs       = the chain class's fields (a chain class is one
//!                         whose fun fields all return the class itself)
//!   - slot semantics    = parameter types: an alias name becomes the slot's
//!                         semantic (UnitDefName -> unit_def_name); a plain
//!                         number parameter falls back to its name (count)
//!   - editor enums      = aliases whose type is a union of string literals
//!
//! Anything typed is understood without kit changes; anything untyped stays
//! the opaque exit hatch. The parser reads the line-oriented LuaCATS subset
//! those files use — it is not a full doc-type parser.
//!
//! The embedded fixtures are snapshots for tests and a fallback when no
//! types/ dir is found near the mission; real runs load the game's files.

use std::collections::BTreeMap;

pub const DSL_SNAPSHOT: &str = include_str!("../fixtures/dsl.lua");
pub const MISSIONS_TYPES_SNAPSHOT: &str = include_str!("../fixtures/missions_types.lua");

#[derive(Debug, Clone)]
pub struct FnSig {
    /// (name, type) per parameter, in order.
    pub params: Vec<(String, String)>,
    pub ret: Option<String>,
}

#[derive(Debug, Clone)]
pub enum Global {
    Fn(FnSig),
    /// `---@type ClassName` or `---@type { Member: ClassName, ... }`,
    /// normalized to member -> type.
    Object(BTreeMap<String, String>),
}

#[derive(Debug, Default)]
pub struct TypeSurface {
    /// alias name -> string literals, for union-of-literals aliases.
    pub aliases: BTreeMap<String, Option<Vec<String>>>,
    /// class name -> field name -> signature (fun-typed fields only).
    pub classes: BTreeMap<String, BTreeMap<String, FnSig>>,
    pub globals: BTreeMap<String, Global>,
}

impl TypeSurface {
    pub fn parse(sources: &[&str]) -> TypeSurface {
        let mut surface = TypeSurface::default();
        for source in sources {
            surface.parse_source(source);
        }
        surface
    }

    /// The snapshot surface: tests, and the fallback when the game tree's
    /// types/ dir is not found near the mission files.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn builtin() -> &'static TypeSurface {
        static BUILTIN: std::sync::OnceLock<TypeSurface> = std::sync::OnceLock::new();
        BUILTIN.get_or_init(|| TypeSurface::parse(&[DSL_SNAPSHOT, MISSIONS_TYPES_SNAPSHOT]))
    }

    /// Load the game's annotation files by walking ancestors of the given
    /// paths for a types/ dir with surface-marked files (mission dirs live
    /// under modules/missions, whose types/ sibling holds the truth). Falls
    /// back to the built-in snapshot when none is found.
    pub fn load_near(paths: &[std::path::PathBuf]) -> TypeSurface {
        for path in paths {
            let start = if path.is_dir() { Some(path.as_path()) } else { path.parent() };
            let mut ancestor = start;
            while let Some(dir) = ancestor {
                let sources = surface_sources(&dir.join("types"));
                if !sources.is_empty() {
                    let refs: Vec<&str> = sources.iter().map(String::as_str).collect();
                    return TypeSurface::parse(&refs);
                }
                ancestor = dir.parent();
            }
        }
        TypeSurface::parse(&[DSL_SNAPSHOT, MISSIONS_TYPES_SNAPSHOT])
    }

    fn parse_source(&mut self, source: &str) {
        let mut current_class: Option<String> = None;
        let mut current_alias: Option<String> = None;
        let mut pending_params: Vec<(String, String)> = Vec::new();
        let mut pending_ret: Option<String> = None;
        let mut pending_type: Option<String> = None;

        for raw in source.lines() {
            let line = raw.trim();
            if let Some(rest) = line.strip_prefix("---@") {
                let (tag, rest) = split_word(rest);
                match tag {
                    "class" => {
                        let (name, _) = split_word(rest);
                        current_class = Some(name.to_string());
                        current_alias = None;
                        self.classes.entry(name.to_string()).or_default();
                    }
                    "field" => {
                        if let Some(class) = &current_class {
                            let (name, rest) = split_word(rest);
                            // A literally-named field may be bracket-quoted
                            // when it collides with a LuaCATS keyword.
                            let name = name
                                .strip_prefix("[\"")
                                .and_then(|n| n.strip_suffix("\"]"))
                                .unwrap_or(name);
                            // parse_fun consumes the whole rest (a fun type
                            // contains spaces); non-fun fields are data, not
                            // grammar, and are skipped.
                            if let Some(sig) = parse_fun(rest) {
                                self.classes
                                    .entry(class.clone())
                                    .or_default()
                                    .insert(name.to_string(), sig);
                            }
                        }
                    }
                    "alias" => {
                        let (name, rest) = split_word(rest);
                        let (type_expr, _) = split_type(rest);
                        let literals = parse_literal_union(type_expr);
                        current_alias = Some(name.to_string());
                        current_class = None;
                        self.aliases.insert(name.to_string(), literals);
                    }
                    "param" => {
                        let (name, rest) = split_word(rest);
                        let (type_expr, _) = split_type(rest);
                        pending_params.push((name.to_string(), type_expr.to_string()));
                    }
                    "return" => {
                        let (type_expr, _) = split_type(rest);
                        pending_ret = Some(type_expr.to_string());
                    }
                    "type" => {
                        pending_type = Some(rest.trim().to_string());
                    }
                    _ => {}
                }
                continue;
            }
            // `---| "literal"` continuation lines extend the open alias union.
            if let Some(rest) = line.strip_prefix("---|") {
                if let Some(alias) = &current_alias {
                    if let Some(literal) = parse_string_literal(rest.trim()) {
                        self.aliases
                            .entry(alias.clone())
                            .or_insert_with(|| Some(Vec::new()))
                            .get_or_insert_with(Vec::new)
                            .push(literal);
                    }
                }
                continue;
            }
            if line.starts_with("---") || line.is_empty() {
                continue;
            }
            current_alias = None;
            // Global function stub: `function Name(...) end`
            if let Some(rest) = line.strip_prefix("function ") {
                if let Some(paren) = rest.find('(') {
                    let name = &rest[..paren];
                    if !name.contains('.') && !name.contains(':') {
                        self.globals.insert(
                            name.to_string(),
                            Global::Fn(FnSig {
                                params: std::mem::take(&mut pending_params),
                                ret: pending_ret.take(),
                            }),
                        );
                    }
                }
            } else if let Some(eq) = line.find(" = ") {
                // Global object stub: `Name = {}` with a pending ---@type.
                let name = &line[..eq];
                if name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
                    if let Some(type_expr) = pending_type.take() {
                        self.globals
                            .insert(name.to_string(), Global::Object(parse_object_type(&type_expr)));
                    }
                }
            }
            pending_params.clear();
            pending_ret = None;
            pending_type = None;
        }
    }

    /// A chain class: at least one field, every field a fun returning the
    /// class itself. These are the builder chains statements are made of.
    pub fn is_chain_class(&self, name: &str) -> bool {
        self.classes
            .get(name)
            .map(|fields| {
                !fields.is_empty() && fields.values().all(|sig| sig.ret.as_deref() == Some(name))
            })
            .unwrap_or(false)
    }

    /// Statement heads: injected globals returning a chain class, mapped to
    /// that class's name.
    pub fn statement_heads(&self) -> BTreeMap<String, String> {
        let mut heads = BTreeMap::new();
        for (name, global) in &self.globals {
            if let Global::Fn(sig) = global {
                if let Some(ret) = &sig.ret {
                    if self.is_chain_class(ret) {
                        heads.insert(name.clone(), ret.clone());
                    }
                }
            }
        }
        heads
    }

    /// The chain verbs a statement head admits (the chain class's fields).
    pub fn chain_verbs(&self, head: &str) -> Vec<String> {
        self.statement_heads()
            .get(head)
            .and_then(|class| self.classes.get(class))
            .map(|fields| fields.keys().cloned().collect())
            .unwrap_or_default()
    }

    /// The signature behind one step of a statement: the head fn itself for
    /// the first invocation, the chain class's field for later ones.
    pub fn step_sig(&self, head: &str, verb: &str) -> Option<&FnSig> {
        if verb == head {
            match self.globals.get(head) {
                Some(Global::Fn(sig)) => Some(sig),
                _ => None,
            }
        } else {
            let class = match self.globals.get(head) {
                Some(Global::Fn(sig)) => sig.ret.as_deref()?,
                _ => return None,
            };
            self.classes.get(class)?.get(verb)
        }
    }

    /// Resolve a dotted path (e.g. Team.Player.Has) to the signature of its
    /// final callable member. Returns None when any hop leaves the surface.
    pub fn resolve_path(&self, path: &str) -> Option<FnSig> {
        let mut segments = path.split('.');
        let first = segments.next()?;
        match self.globals.get(first)? {
            Global::Fn(sig) => {
                // A bare global fn path has no further segments.
                if segments.next().is_some() {
                    return None;
                }
                Some(sig.clone())
            }
            Global::Object(members) => {
                // A bare `---@type ClassName` object stores its class under
                // the "" marker; member lookups then go through the class.
                let mut current_class = members.get("").cloned();
                let mut object_members = if current_class.is_some() { None } else { Some(members) };
                for segment in segments {
                    if let Some(m) = object_members {
                        let type_name = m.get(segment)?.clone();
                        if self.classes.contains_key(&type_name) {
                            current_class = Some(type_name);
                            object_members = None;
                        } else {
                            return None;
                        }
                    } else {
                        // Field lookup in the current class ends the path.
                        let class = current_class.as_deref()?;
                        return self.classes.get(class)?.get(segment).cloned();
                    }
                }
                None
            }
        }
    }

    /// The signature of `.name(...)` chained after something returning
    /// `class` (or of `class`'s member for the first named call).
    pub fn member_sig(&self, class: &str, name: &str) -> Option<&FnSig> {
        self.classes.get(class)?.get(name)
    }

    /// The semantic slug a parameter type carries, if any: a declared alias
    /// becomes snake_case with the Mission prefix dropped.
    pub fn semantic_for(&self, type_name: &str) -> Option<String> {
        if self.aliases.contains_key(type_name) {
            Some(alias_slug(type_name))
        } else {
            None
        }
    }

    /// semantic slug -> options, for aliases that are literal unions.
    pub fn enums(&self) -> BTreeMap<String, Vec<String>> {
        let mut out = BTreeMap::new();
        for (name, literals) in &self.aliases {
            if let Some(options) = literals {
                if !options.is_empty() {
                    out.insert(alias_slug(name), options.clone());
                }
            }
        }
        out
    }
}

/// The self-declaration a file makes to join the published DSL surface: a
/// named LuaCATS meta marker at the top. Composition is declarative — every
/// marked .lua file in the discovered types/ dir is parsed, in filename
/// order; scratch and proposal files stay out by not marking themselves.
pub const SURFACE_MARKER: &str = "---@meta dsl";

fn declares_surface(source: &str) -> bool {
    source.lines().take(4).any(|line| line.trim() == SURFACE_MARKER)
}

fn surface_sources(types_dir: &std::path::Path) -> Vec<String> {
    let mut files: Vec<std::path::PathBuf> = std::fs::read_dir(types_dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().map(|x| x == "lua").unwrap_or(false))
        .collect();
    files.sort();
    files
        .into_iter()
        .filter_map(|path| std::fs::read_to_string(path).ok())
        .filter(|source| declares_surface(source))
        .collect()
}

/// MissionUnitName -> unit_name, UnitDefName -> unit_def_name.
pub fn alias_slug(name: &str) -> String {
    let name = name.strip_prefix("Mission").unwrap_or(name);
    let mut out = String::new();
    for (i, c) in name.chars().enumerate() {
        if c.is_ascii_uppercase() {
            if i > 0 {
                out.push('_');
            }
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

fn split_word(text: &str) -> (&str, &str) {
    let text = text.trim_start();
    match text.find(char::is_whitespace) {
        Some(at) => (&text[..at], text[at..].trim_start()),
        None => (text, ""),
    }
}

/// Split one type expression off the front of `text`. Whitespace ends it,
/// except inside (), <> or {} — so `fun(a: T, b: U): R`, `table<K, V>` and
/// `{ A: B }` survive; the trailing prose comment does not.
fn split_type(text: &str) -> (&str, &str) {
    let text = text.trim_start();
    let mut depth = 0usize;
    for (i, c) in text.char_indices() {
        match c {
            '(' | '<' | '{' | '[' => depth += 1,
            ')' | '>' | '}' | ']' => depth = depth.saturating_sub(1),
            c if c.is_whitespace() && depth == 0 => {
                return (&text[..i], text[i..].trim_start());
            }
            _ => {}
        }
    }
    (text, "")
}

/// `fun(a: T, b: U): R` -> FnSig. None when the expression is not a fun type.
fn parse_fun(type_expr: &str) -> Option<FnSig> {
    let rest = type_expr.strip_prefix("fun(")?;
    let close = matching_paren(rest)?;
    let params_text = &rest[..close];
    let after = &rest[close + 1..];
    let ret = after
        .strip_prefix(':')
        .map(|r| split_type(r.trim_start()).0.to_string());
    let mut params = Vec::new();
    for part in split_top_level(params_text, ',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        match part.split_once(':') {
            Some((name, type_name)) => {
                params.push((name.trim().to_string(), type_name.trim().to_string()))
            }
            None => params.push((part.to_string(), String::new())),
        }
    }
    Some(FnSig { params, ret })
}

fn matching_paren(text: &str) -> Option<usize> {
    let mut depth = 0usize;
    for (i, c) in text.char_indices() {
        match c {
            '(' => depth += 1,
            ')' => {
                if depth == 0 {
                    return Some(i);
                }
                depth -= 1;
            }
            _ => {}
        }
    }
    None
}

fn split_top_level(text: &str, separator: char) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut depth = 0usize;
    let mut start = 0usize;
    for (i, c) in text.char_indices() {
        match c {
            '(' | '<' | '{' | '[' => depth += 1,
            ')' | '>' | '}' | ']' => depth = depth.saturating_sub(1),
            c if c == separator && depth == 0 => {
                parts.push(&text[start..i]);
                start = i + c.len_utf8();
            }
            _ => {}
        }
    }
    parts.push(&text[start..]);
    parts
}

/// `"a"|"b"|"c"` -> Some([a, b, c]); anything else -> None.
fn parse_literal_union(type_expr: &str) -> Option<Vec<String>> {
    let mut literals = Vec::new();
    for part in split_top_level(type_expr, '|') {
        literals.push(parse_string_literal(part.trim())?);
    }
    if literals.is_empty() {
        None
    } else {
        Some(literals)
    }
}

fn parse_string_literal(text: &str) -> Option<String> {
    let text = split_type(text).0;
    let rest = text.strip_prefix('"')?;
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

/// `{ Player: MissionTeam, ... }` -> member map; a bare class name becomes a
/// synthetic object whose members are that class's fields (resolved lazily by
/// callers via classes) — here it is stored as a single "" -> name marker.
fn parse_object_type(type_expr: &str) -> BTreeMap<String, String> {
    let mut members = BTreeMap::new();
    let inner = type_expr
        .trim()
        .strip_prefix('{')
        .and_then(|t| t.strip_suffix('}'));
    match inner {
        Some(inner) => {
            for part in split_top_level(inner, ',') {
                if let Some((name, type_name)) = part.split_once(':') {
                    members.insert(name.trim().to_string(), type_name.trim().to_string());
                }
            }
        }
        None => {
            members.insert(String::new(), type_expr.trim().to_string());
        }
    }
    members
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_snapshot_surface_derives_the_statement_grammar() {
        let surface = TypeSurface::builtin();
        let heads = surface.statement_heads();
        assert_eq!(heads.get("When").map(String::as_str), Some("TriggerChain"));
        assert_eq!(heads.get("Spawn").map(String::as_str), Some("MissionSpawnChain"));
        // condition/effect builders are not statement heads
        assert!(!heads.contains_key("Objective"));
        assert!(!heads.contains_key("Unit"));

        let mut when_verbs = surface.chain_verbs("When");
        when_verbs.sort();
        assert_eq!(when_verbs, vec!["Do", "Once", "When"]);
        let mut spawn_verbs = surface.chain_verbs("Spawn");
        spawn_verbs.sort();
        assert_eq!(spawn_verbs, vec!["At", "Grouped", "Named"]);
    }

    #[test]
    fn semantics_come_from_param_aliases() {
        let surface = TypeSurface::builtin();
        let unit_def = match surface.globals.get("UnitDef") {
            Some(Global::Fn(sig)) => sig.clone(),
            other => panic!("UnitDef should be a global fn, got {other:?}"),
        };
        assert_eq!(surface.semantic_for(&unit_def.params[0].1).as_deref(), Some("unit_def_name"));

        let named = surface.step_sig("Spawn", "Named").expect("Named on the spawn chain");
        assert_eq!(surface.semantic_for(&named.params[0].1).as_deref(), Some("unit_name"));

        let spawn = surface.step_sig("Spawn", "Spawn").expect("the head itself");
        assert_eq!(surface.semantic_for(&spawn.params[1].1).as_deref(), Some("team_role"));
    }

    #[test]
    fn literal_union_aliases_become_editor_enums() {
        let enums = TypeSurface::builtin().enums();
        assert_eq!(
            enums.get("team_role"),
            Some(&vec!["player".to_string(), "enemy".to_string(), "gaia".to_string()])
        );
    }

    #[test]
    fn dotted_paths_resolve_through_object_globals() {
        let surface = TypeSurface::builtin();
        let has = surface.resolve_path("Team.Player.Has").expect("Team.Player.Has");
        assert_eq!(has.params[1].0, "count");
        assert_eq!(has.ret.as_deref(), Some("MissionCondition"));
        assert!(surface.resolve_path("Team.Nobody.Has").is_none());
    }

    #[test]
    fn fun_types_with_generic_returns_parse() {
        let mut surface = TypeSurface::default();
        surface.parse_source(
            "---@class Thing\n---@field Watched fun(): table<string, boolean> the watch set\n",
        );
        let sig = &surface.classes["Thing"]["Watched"];
        assert_eq!(sig.ret.as_deref(), Some("table<string, boolean>"));
    }

    #[test]
    fn the_surface_is_composed_of_self_declared_files() {
        let dir = std::env::temp_dir().join(format!("bmk-marker-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("types")).unwrap();
        std::fs::write(
            dir.join("types/dsl.lua"),
            "---@meta dsl\n\n---@param name UnitDefName\n---@return MissionUnitDefRef\nfunction UnitDef(name) end\n",
        )
        .unwrap();
        // A second marked file composes in (the distributed-modules shape).
        std::fs::write(
            dir.join("types/extra.lua"),
            "---@meta dsl\n\n---@alias UnitDefName string\n",
        )
        .unwrap();
        // Scratch stays out: annotation-shaped but not self-declared.
        std::fs::write(
            dir.join("types/dsl_proposed.lua"),
            "---@meta\n\n---@return TriggerChain\nfunction Ban(name) end\n",
        )
        .unwrap();

        let surface = TypeSurface::load_near(&[dir.join("some_mission")]);
        assert!(surface.globals.contains_key("UnitDef"));
        assert!(surface.aliases.contains_key("UnitDefName"), "composed from the second file");
        assert!(!surface.globals.contains_key("Ban"), "unmarked scratch must stay out");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn alias_slugs_drop_the_mission_prefix() {
        assert_eq!(alias_slug("MissionUnitName"), "unit_name");
        assert_eq!(alias_slug("UnitDefName"), "unit_def_name");
        assert_eq!(alias_slug("MissionTeamRole"), "team_role");
    }
}
