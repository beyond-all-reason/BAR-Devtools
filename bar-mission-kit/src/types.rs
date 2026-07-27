//! The type surface: the kit's model of the mission DSL, derived from the
//! game's LuaCATS annotation files under types/. Statement heads and chain
//! verbs come from the injected globals and chain classes; alias names
//! become slot semantics (UnitDefName -> unit_def_name), and literal-union
//! aliases become editor enums. Anything untyped stays the opaque exit
//! hatch. The parser reads the line-oriented LuaCATS subset those files
//! use — it is not a full doc-type parser.
//!
//! Embedded fixtures are the snapshot used by tests and as a fallback when
//! no types/ dir is found near the mission.

use std::collections::BTreeMap;

/// The game's published DSL types, one file per module exactly as the game
/// ships them — never merged. A merged copy hid a rename once: two modules'
/// vocabulary fused into one file cannot be diffed against either module.
/// `just bar::sync-kit-fixtures --check` fails when these drift.
pub const SNAPSHOTS: &[&str] = &[
    include_str!("../fixtures/modules/missions/types/missions.lua"),
    include_str!("../fixtures/modules/missions/types/mode_dsl.lua"),
    include_str!("../fixtures/modules/missions/types/dsl.lua"),
    include_str!("../fixtures/modules/combat/types/dsl.lua"),
    include_str!("../fixtures/modules/matchflow/types/dsl.lua"),
    include_str!("../fixtures/modules/transfer/types/actions.lua"),
    include_str!("../fixtures/modules/transfer/types/mode_dsl.lua"),
];

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
    /// class name -> field name -> the class that field is typed as. Kept so a
    /// field whose type is a CALLABLE class (an action: `---@overload`) can be
    /// resolved into a signature once every source has been read.
    class_typed_fields: BTreeMap<String, BTreeMap<String, String>>,
}

impl TypeSurface {
    pub fn parse(sources: &[&str]) -> TypeSurface {
        let mut surface = TypeSurface::default();
        for source in sources {
            surface.parse_source(source);
        }
        surface.resolve_callable_fields();
        surface
    }

    /// An action is declared as a class that is callable (`---@overload`), and
    /// referenced as a field typed with that class. Resolve those fields to
    /// the call signature, so one declaration answers both grammars: the mode
    /// reads the field, the mission calls it.
    fn resolve_callable_fields(&mut self) {
        let resolved: Vec<(String, String, FnSig)> = self
            .class_typed_fields
            .iter()
            .flat_map(|(class, fields)| fields.iter().map(move |(f, ty)| (class, f, ty)))
            .filter_map(|(class, field, ty)| {
                let sig = self.classes.get(ty)?.get(CALLABLE)?;
                Some((class.clone(), field.clone(), sig.clone()))
            })
            .collect();
        for (class, field, sig) in resolved {
            self.classes.entry(class).or_default().insert(field, sig);
        }
    }

    /// The snapshot surface: tests, and the fallback when the game tree's
    /// types/ dir is not found near the mission files.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn builtin() -> &'static TypeSurface {
        static BUILTIN: std::sync::OnceLock<TypeSurface> = std::sync::OnceLock::new();
        BUILTIN.get_or_init(|| TypeSurface::parse(SNAPSHOTS))
    }

    /// Load the game's annotation files by walking ancestors of the given
    /// paths for a types/ dir with surface-marked files. Falls back to the
    /// built-in snapshot when none is found.
    pub fn load_near(paths: &[std::path::PathBuf]) -> TypeSurface {
        for path in paths {
            if let Some(dir) = TypeSurface::types_dir_near(path) {
                // A module's surface = its own marked types plus the marked
                // types of every module its manifest requires (transitively):
                // vocabulary travels with the module that injects it, and the
                // manifest graph is what composes the sandbox.
                let mut sources = Vec::new();
                let mut seen = std::collections::BTreeSet::new();
                let mut queue = vec![dir.clone()];
                while let Some(types_dir) = queue.pop() {
                    if !seen.insert(types_dir.clone()) {
                        continue;
                    }
                    for name in manifest_requires(&types_dir) {
                        if let Some(module_dir) = types_dir.parent().and_then(|m| m.parent()) {
                            let required = module_dir.join(&name).join("types");
                            if !surface_sources(&required, Sandbox::Mission).is_empty() {
                                queue.push(required);
                            }
                        }
                    }
                    sources.extend(surface_sources(&types_dir, Sandbox::Mission));
                }
                let refs: Vec<&str> = sources.iter().map(String::as_str).collect();
                return TypeSurface::parse(&refs);
            }
        }
        TypeSurface::parse(SNAPSHOTS)
    }

    /// The nearest ancestor types/ dir containing surface-marked files —
    /// the per-file surface cache key.
    pub fn types_dir_near(path: &std::path::Path) -> Option<std::path::PathBuf> {
        let start = if path.is_dir() { Some(path) } else { path.parent() };
        let mut ancestor = start;
        while let Some(dir) = ancestor {
            let candidate = dir.join("types");
            if !surface_sources(&candidate, Sandbox::Mission).is_empty() {
                return Some(candidate);
            }
            ancestor = dir.parent();
        }
        None
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
                            } else {
                                // Not a fun: remember what class it IS, in case
                                // that class turns out to be callable.
                                let (ty, _) = split_word(rest);
                                self.class_typed_fields
                                    .entry(class.clone())
                                    .or_default()
                                    .insert(name.to_string(), ty.to_string());
                            }
                        }
                    }
                    // `---@overload fun(...)` on a class: the class itself is
                    // callable. Stored under a reserved key so a field typed
                    // with it resolves to this signature.
                    "overload" => {
                        if let Some(class) = &current_class {
                            if let Some(sig) = parse_fun(rest) {
                                self.classes
                                    .entry(class.clone())
                                    .or_default()
                                    .insert(CALLABLE.to_string(), sig);
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

    /// Classify a class's callable fields by what they return, recording them
    /// under `prefix` (Combat -> Combat.Protect, Unit -> Unit().IsDestroyed).
    fn walk_class(&self, class: &str, prefix: &str, roles: &mut Roles) {
        let Some(fields) = self.classes.get(class) else {
            roles.nouns.push(prefix.to_string());
            return;
        };
        if fields.is_empty() {
            roles.nouns.push(prefix.to_string());
            return;
        }
        for (field, sig) in fields {
            if field == CALLABLE {
                continue; // the class's own call, reported by whoever names it
            }
            let name = format!("{prefix}.{field}");
            match sig.ret.as_deref() {
                Some(ret) if ret == class => {}
                Some("MissionCondition") => roles.conditions.push(name),
                Some(ret) if ret.contains("Effect") => roles.effects.push(name),
                Some(ret) if self.classes.contains_key(ret) => self.walk_class(ret, &name, roles),
                _ => roles.nouns.push(name),
            }
        }
        // Fields typed with a class that is NOT callable: an action's mode
        // facet, which a grant is written against. Dropping them would lose
        // half of what a single declaration says.
        for (field, ty) in self.class_typed_fields.get(class).into_iter().flatten() {
            if fields.contains_key(field) {
                continue; // already reported through its call signature
            }
            let name = format!("{prefix}.{field}");
            if self.classes.get(ty).map(|f| f.is_empty()).unwrap_or(true) {
                roles.nouns.push(name);
            } else {
                self.walk_class(ty, &name, roles);
            }
        }
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

/// A file joins a published DSL surface by opening with one of these LuaCATS
/// meta markers, which name WHICH surface. Both grammars talk about the same
/// module actions — Transfer.Units is a thing a mission does and a thing a
/// mode permits — but they say different things about them, so they are
/// parsed apart. Merged, the winner was whichever file was read last, and the
/// two readers disagreed on the order.
/// Reserved field key for a class's own call signature (`---@overload`).
pub const CALLABLE: &str = "__call";

pub const MISSION_MARKER: &str = "---@meta mission_dsl";
pub const MODE_MARKER: &str = "---@meta mode_dsl";
/// A module's actions, declared once and read by both grammars. This is the
/// marker that makes .Allow(Transfer.Units) and Do(Transfer.Units(...)) the
/// same entry rather than two that agree.
pub const ACTIONS_MARKER: &str = "---@meta actions";

/// Which sandbox a surface file publishes into.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sandbox {
    /// A mission's trigger files: do this action, now.
    Mission,
    /// A mode preset: this action is permitted, on these terms.
    Mode,
}

/// Whether a file publishes into the given sandbox: its own, or both.
fn publishes_into(source: &str, sandbox: Sandbox) -> bool {
    source.lines().take(4).any(|line| match line.trim() {
        ACTIONS_MARKER => true,
        MISSION_MARKER => sandbox == Sandbox::Mission,
        MODE_MARKER => sandbox == Sandbox::Mode,
        _ => false,
    })
}

/// The `requires = { "name", ... }` list from the module.lua manifest sitting
/// beside a types/ dir; empty when there is no manifest.
fn manifest_requires(types_dir: &std::path::Path) -> Vec<String> {
    let Some(module_dir) = types_dir.parent() else {
        return Vec::new();
    };
    let Ok(manifest) = std::fs::read_to_string(module_dir.join("module.lua")) else {
        return Vec::new();
    };
    let Some(open) = manifest.find("requires") else {
        return Vec::new();
    };
    let Some(start) = manifest[open..].find('{').map(|i| open + i + 1) else {
        return Vec::new();
    };
    let Some(end) = manifest[start..].find('}').map(|i| start + i) else {
        return Vec::new();
    };
    manifest[start..end]
        .split(',')
        .filter_map(|entry| {
            let entry = entry.trim().trim_matches(|c| c == '"' || c == '\'');
            (!entry.is_empty()).then(|| entry.to_string())
        })
        .collect()
}

fn surface_sources(types_dir: &std::path::Path, sandbox: Sandbox) -> Vec<String> {
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
        .filter(|source| publishes_into(source, sandbox))
        .collect()
}

/// A statement head and the steps that chain onto it.
#[derive(Debug, Clone, serde::Serialize, Default)]
pub struct Statement {
    pub name: String,
    pub steps: Vec<String>,
}

/// The roles a module's surface fills, as the author thinks of them.
#[derive(Default)]
pub struct Roles {
    pub statements: Vec<Statement>,
    pub conditions: Vec<String>,
    pub effects: Vec<String>,
    pub nouns: Vec<String>,
}

/// An example call for a published verb, built from its signature. The palette
/// used to hand-write these, which meant a renamed verb left a template nobody
/// could run — the types are the only authored copy, so derive from them.
impl TypeSurface {
    /// Roles derived from return types: a callable returning a condition is
    /// something a When can ask, one returning an effect is something a Do can
    /// run, a self-returning chain field is a step of its statement.
    pub fn roles(&self) -> Roles {
        let mut roles = Roles::default();
        for (name, global) in &self.globals {
            match global {
                Global::Fn(sig) => match sig.ret.as_deref() {
                    Some(ret) if self.is_chain_class(ret) => {
                        let mut steps: Vec<String> = self
                            .classes
                            .get(ret)
                            .map(|fields| fields.keys().map(|f| format!(".{f}")).collect())
                            .unwrap_or_default();
                        steps.sort();
                        roles.statements.push(Statement { name: name.clone(), steps });
                    }
                    Some(ret) => self.walk_class(ret, name, &mut roles),
                    None => {}
                },
                Global::Object(members) => {
                    if let Some(class) = members.get("") {
                        self.walk_class(class, name, &mut roles);
                    } else {
                        for (member, class) in members {
                            self.walk_class(class, &format!("{name}.{member}"), &mut roles);
                        }
                    }
                }
            }
        }
        roles
    }

    pub fn template_for(&self, path: &str) -> Option<String> {
        let mut segments = path.split('.');
        let root = segments.next()?;
        let mut out = String::from(root);
        let mut class = match self.globals.get(root)? {
            Global::Fn(sig) => {
                out.push_str(&self.arguments(sig));
                sig.ret.clone()?
            }
            Global::Object(members) => match members.get("") {
                // `---@type Class`: the global IS the class; segments that
                // follow are its fields.
                Some(class) => class.clone(),
                // `---@type { Member: Class }`: the next segment names a member.
                None => {
                    let next = segments.next()?;
                    out.push('.');
                    out.push_str(next);
                    members.get(next)?.clone()
                }
            },
        };
        for segment in segments {
            let sig = self.classes.get(&class)?.get(segment)?;
            out.push('.');
            out.push_str(segment);
            // Namespace or call, decided exactly as walk_class decides roles:
            // conditions and effects are calls even though their returns are
            // classes; anything else returning a class is a namespace.
            let namespace = match sig.ret.as_deref() {
                Some("MissionCondition") => false,
                Some(ret) if ret.contains("Effect") => false,
                Some(ret) => self.classes.contains_key(ret),
                None => false,
            };
            if !namespace {
                out.push_str(&self.arguments(sig));
            }
            class = sig.ret.clone().unwrap_or_default();
        }
        Some(out)
    }

    fn arguments(&self, sig: &FnSig) -> String {
        let args: Vec<String> = sig.params.iter().map(|(_, ty)| self.example(ty)).collect();
        format!("({})", args.join(", "))
    }

    /// A stand-in value per parameter type. Placeholders are shouted so an
    /// author sees what still needs filling in.
    fn example(&self, ty: &str) -> String {
        match ty.trim_end_matches('?') {
            "MissionUnitGroup" => "\"GROUP\"".into(),
            "MissionUnitName" => "\"UNIT_NAME\"".into(),
            "ObjectiveName" => "\"OBJECTIVE\"".into(),
            "MissionUnitGroupName" => "\"GROUP\"".into(),
            "UnitDefName" => "\"armpw\"".into(),
            "MissionTeam" => "Team.Player".into(),
            "MissionTeamRole" => "\"player\"".into(),
            "MissionUnitRef" => "Unit(\"UNIT_NAME\")".into(),
            "MissionUnitDefRef" => "UnitDef(\"armpw\")".into(),
            "MissionObjective" => "Objective(\"OBJECTIVE\")".into(),
            "MissionCondition" => "Objective(\"OBJECTIVE\").IsComplete()".into(),
            "MissionEffect" => "Objective(\"OBJECTIVE\").Complete()".into(),
            "integer" | "number" => "3".into(),
            "boolean" => "true".into(),
            "string" => "\"TEXT\"".into(),
            other => {
                // A literal-union alias is its own best example.
                match self.aliases.get(other) {
                    Some(Some(values)) if !values.is_empty() => format!("\"{}\"", values[0]),
                    _ => "nil".into(),
                }
            }
        }
    }
}

/// One module as the editor shows it: what it is, what it requires, and what
/// vocabulary it puts in the sandbox. Derived from the same marked types the
/// grammar comes from — a module that publishes a surface is explorable, no
/// registration anywhere.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ModuleInfo {
    pub name: String,
    pub description: String,
    pub requires: Vec<String>,
    /// Statement heads with the steps each one takes: a step means nothing
    /// apart from the statement it belongs to (.At is Spawn's, not Mode's).
    pub statements: Vec<Statement>,
    /// Callables returning a condition (what a When can ask).
    pub conditions: Vec<String>,
    /// Callables returning an effect (what a Do can run).
    pub effects: Vec<String>,
    /// Nouns a verb takes as its subject (Share.Units, Match.End).
    pub nouns: Vec<String>,
    /// Mode presets shipped under <module>/modes/.
    pub modes: Vec<String>,
}

/// Read one field out of a module.lua manifest (`name = "x"` / `description = "y"`).
fn manifest_field(manifest: &str, field: &str) -> Option<String> {
    let at = manifest.find(&format!("{field}"))?;
    let rest = &manifest[at..];
    let eq = rest.find('=')?;
    let tail = rest[eq + 1..].trim_start();
    let quote = tail.chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    let body = &tail[1..];
    let end = body.find(quote)?;
    Some(body[..end].to_string())
}

/// Every module under the modules root that publishes a marked surface.
pub fn explore_modules(modules_root: &std::path::Path) -> Vec<ModuleInfo> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(modules_root) else {
        return out;
    };
    let mut dirs: Vec<std::path::PathBuf> =
        entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
    dirs.sort();
    for dir in dirs {
        let mission_sources = surface_sources(&dir.join("types"), Sandbox::Mission);
        let mode_sources = surface_sources(&dir.join("types"), Sandbox::Mode);
        let manifest = std::fs::read_to_string(dir.join("module.lua")).unwrap_or_default();
        if mission_sources.is_empty() && mode_sources.is_empty() && manifest.is_empty() {
            continue;
        }
        let name = dir
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or_default()
            .to_string();
        // Roles are derivable from return types, so derive them: a callable
        // returning a condition is something a When can ask, one returning an
        // effect is something a Do can run, and a self-returning chain field
        // is a step of the statement it belongs to. Each sandbox derives from
        // its own parse — the module card shows both, but a mode grant never
        // becomes the answer to what a mission verb means.
        let roles_of = |sources: &[String]| {
            let refs: Vec<&str> = sources.iter().map(String::as_str).collect();
            TypeSurface::parse(&refs).roles()
        };
        let mission = roles_of(&mission_sources);
        let mode = roles_of(&mode_sources);
        let mut statements = mission.statements;
        let mut conditions = mission.conditions;
        let mut effects = mission.effects;
        let mut nouns = mission.nouns;
        statements.extend(mode.statements);
        conditions.extend(mode.conditions);
        effects.extend(mode.effects);
        nouns.extend(mode.nouns);
        statements.sort_by(|a, b| a.name.cmp(&b.name));
        for list in [&mut conditions, &mut effects, &mut nouns] {
            list.sort();
            list.dedup();
        }
        let mut modes: Vec<String> = std::fs::read_dir(dir.join("modes"))
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| {
                let p = e.path();
                (p.extension().map(|x| x == "lua").unwrap_or(false))
                    .then(|| p.file_stem()?.to_str().map(|s| s.to_string()))
                    .flatten()
            })
            .collect();
        modes.sort();
        out.push(ModuleInfo {
            description: manifest_field(&manifest, "description").unwrap_or_default(),
            requires: manifest_requires(&dir.join("types")),
            name,
            statements,
            conditions,
            effects,
            nouns,
            modes,
        });
    }
    out
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
            "---@meta mission_dsl\n\n---@param name UnitDefName\n---@return MissionUnitDefRef\nfunction UnitDef(name) end\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("types/extra.lua"),
            "---@meta mission_dsl\n\n---@alias UnitDefName string\n",
        )
        .unwrap();
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
    fn a_modules_surface_composes_through_its_manifest_requires() {
        let dir = std::env::temp_dir().join(format!("bmk-requires-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for module in ["alpha", "beta"] {
            std::fs::create_dir_all(dir.join("modules").join(module).join("types")).unwrap();
        }
        std::fs::write(
            dir.join("modules/alpha/module.lua"),
            "return { name = \"alpha\", requires = { \"beta\" } }\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("modules/alpha/types/dsl.lua"),
            "---@meta mission_dsl\n\n---@class AlphaChain\n---@field Do fun(e: table): AlphaChain\n\n---@return AlphaChain\nfunction When(c) end\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("modules/beta/types/dsl.lua"),
            "---@meta mission_dsl\n\n---@class BetaVerbs\n---@field Zap fun(): table\n\n---@type BetaVerbs\nBeta = {}\n",
        )
        .unwrap();

        let surface = TypeSurface::load_near(&[dir.join("modules/alpha/some_mission/triggers")]);
        assert!(surface.statement_heads().contains_key("When"), "own vocabulary");
        assert!(surface.globals.contains_key("Beta"), "required module's vocabulary composes in");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn alias_slugs_drop_the_mission_prefix() {
        assert_eq!(alias_slug("MissionUnitName"), "unit_name");
        assert_eq!(alias_slug("UnitDefName"), "unit_def_name");
        assert_eq!(alias_slug("MissionTeamRole"), "team_role");
    }
}
