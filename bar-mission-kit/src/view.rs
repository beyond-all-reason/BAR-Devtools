//! Server-side view rendering: AST -> markup, Dioxus RSX components SSR'd to
//! strings. The markup stays inside the HTML/RML intersection (div, span,
//! button, input, select, class + data-* attributes) so every client is a
//! blind terminal: the game injects it via inner_rml with an RCSS theme, a
//! webview injects it via innerHTML with a CSS theme. Clients route events by
//! data-* attributes only — no mission knowledge outside this file.

use crate::model::{FileAst, MissionAst, Span, Step, Trigger, Value};
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Domain lists only a client can know (the game owns UnitDefNames). Clients
/// publish this as domains.json in the editor dir; serve folds it into the
/// next generation.
#[derive(Deserialize, Default, Clone)]
pub struct Domains {
    #[serde(default)]
    pub units: Vec<DomainOption>,
}

#[derive(Deserialize, Serialize, Clone)]
pub struct DomainOption {
    pub value: String,
    pub label: String,
}

/// Where the served mission sits in the missions tree. Serve owns this (it
/// knows --missions-root); the crumb and mission list render server-side so
/// terminals stay blind.
#[derive(Default, Clone)]
pub struct Scope {
    pub mission: Option<String>,
    pub missions: Vec<String>,
}

/// The rendered view artifact (mission_view.json). `generation` first: the
/// widget greps it cheaply before decoding.
#[derive(Serialize)]
pub struct ViewArtifact {
    pub generation: u64,
    pub first_file: Option<String>,
    /// Editable card view (sentence forms with controls in the slots).
    pub form: String,
    /// Read-only display-notation view for the text-mode billboard.
    pub billboard: String,
    pub modals: Modals,
    /// Live-state probes: the game samples these (state.json / GET /state)
    /// and terminals patch the matching [data-live] chips in place. Telemetry
    /// deliberately bypasses the generation counter — values change without
    /// re-rendering the form.
    pub live: Vec<LiveProbe>,
    /// The DSL vocabulary for editor completion: trigger files aren't Lua
    /// project members, so their completion comes from here, not a Lua LS.
    pub vocabulary: Vocabulary,
}

#[derive(Serialize)]
pub struct Vocabulary {
    pub conditions: Vec<SurfaceEntry>,
    pub effects: Vec<SurfaceEntry>,
    pub objectives: Vec<String>,
    pub units: Vec<DomainOption>,
    /// Roster-declared unit and group names (units.lua) — the legal values
    /// for Unit()/Units.* slots.
    pub unit_names: Vec<String>,
    pub groups: Vec<String>,
}

/// One thing the game should sample. `key` matches a data-live attribute in
/// the form; content-derived so it stays stable across regenerations.
#[derive(Serialize, Clone)]
pub struct LiveProbe {
    pub key: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit_def: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub need: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub objective: Option<String>,
    /// Roster name for the named-unit kinds (unit_dead, unit_spotted).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit_name: Option<String>,
    /// Director name for the wave kinds, lowercased from the pack reference
    /// the mission wrote (`Scavengers.Skirmish` -> `scavengers.skirmish`).
    /// That is the name the director publishes its counters under.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pack: Option<String>,
    /// `<file>:<order>` for the trigger kind — the same identity the runtime
    /// stamps, minus the mission prefix the game adds back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trigger: Option<String>,
}

#[derive(Serialize)]
pub struct Modals {
    pub add_step: Modal,
    pub add_statement: Modal,
    /// The roster's own palette: spawn chains, not trigger vocabulary.
    pub add_spawn: Modal,
    pub swap_conditions: Modal,
    pub swap_effects: Modal,
}

/// Modal content is structured data, not markup: `new_text` carries newlines,
/// which XML attributes cannot. The terminal lists labels and posts the
/// opaque `new_text` at a position chosen by `kind`:
///   group   — section header, not clickable
///   trigger — insert at the button's data-insert
///   andwhen — insert at the button's data-insert-cond
///   effect  — insert at the button's data-insert-effect
///   swap    — replace the button's data-swap-start..data-swap-end
#[derive(Serialize)]
pub struct Modal {
    pub title: String,
    pub rows: Vec<ModalRow>,
}

#[derive(Serialize)]
pub struct ModalRow {
    pub kind: String,
    pub label: String,
    #[serde(default)]
    pub new_text: String,
}

#[derive(Deserialize, Clone, Default)]
struct StatementInfo {
    name: String,
    #[serde(default)]
    steps: Vec<String>,
}

#[derive(Deserialize, Clone, Default)]
struct ModuleInfo {
    name: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    requires: Vec<String>,
    #[serde(default)]
    statements: Vec<StatementInfo>,
    #[serde(default)]
    conditions: Vec<String>,
    #[serde(default)]
    effects: Vec<String>,
    #[serde(default)]
    nouns: Vec<String>,
    #[serde(default)]
    modes: Vec<String>,
}

#[derive(Deserialize, Clone, Default)]
struct Surface {
    #[serde(default)]
    conditions: Vec<SurfaceEntry>,
    #[serde(default)]
    effects: Vec<SurfaceEntry>,
    /// semantic -> options, derived from literal-union type aliases
    /// (collect_ast merges them into the surface overlay).
    #[serde(default)]
    enums: std::collections::BTreeMap<String, Vec<String>>,
    /// Modules publishing a marked DSL surface (the explorer's rows).
    #[serde(default)]
    modules: Vec<ModuleInfo>,
    /// Roster chains. Curated, not derived: a spawn position is a map
    /// fraction, and `number` cannot say that.
    #[serde(default)]
    spawns: Vec<SurfaceEntry>,
}

#[derive(Deserialize, Serialize, Clone)]
pub struct SurfaceEntry {
    label: String,
    template: String,
}

#[derive(Clone, Copy, PartialEq)]
enum Style {
    Ui,
    Dsl,
}

struct Ctx<'a> {
    file: &'a str,
    hash: &'a str,
    editable: bool,
    style: Style,
    surface: &'a Surface,
    domains: &'a Domains,
    live: &'a std::cell::RefCell<Vec<LiveProbe>>,
}

/// Unit def names the game does not publish. The roster's own names are
/// cross-checked against units.lua; these are game content, so the only
/// authority is what the bridge published in domains.json — and when nothing
/// has been published (a headless check, a game that has not run) there is no
/// authority and no finding, rather than a wall of false positives.
pub fn unknown_unit_defs(ast: &MissionAst, domains: &Domains) -> Vec<crate::model::Finding> {
    if domains.units.is_empty() {
        return Vec::new();
    }
    let known: std::collections::HashSet<&str> =
        domains.units.iter().map(|u| u.value.as_str()).collect();
    fn walk<'a>(value: &'a Value, out: &mut Vec<(&'a str, crate::model::Span)>) {
        match value {
            Value::String { value, span, semantic: Some(s) } if s == "unit_def_name" => {
                out.push((value, *span))
            }
            Value::Verb { calls, .. } => {
                for c in calls {
                    for a in &c.args {
                        walk(a, out);
                    }
                }
            }
            Value::Table { fields, .. } => {
                for f in fields {
                    walk(&f.value, out);
                }
            }
            _ => {}
        }
    }
    let mut findings = Vec::new();
    for file in &ast.files {
        for group in &file.groups {
            for trigger in &group.triggers {
                for step in &trigger.steps {
                    let mut names = Vec::new();
                    for arg in &step.args {
                        walk(arg, &mut names);
                    }
                    for (name, span) in names {
                        if !known.contains(name) {
                            findings.push(crate::model::Finding {
                                path: file.path.clone(),
                                line: step.line,
                                message: format!(
                                    "UnitDef(\"{name}\"): the game publishes no such unit def"
                                ),
                                span: Some(span),
                            });
                        }
                    }
                }
            }
        }
    }
    findings
}

pub fn render(ast: &MissionAst, domains: &Domains, scope: &Scope) -> ViewArtifact {
    let surface: Surface = serde_json::from_value(ast.surface.clone()).unwrap_or_default();
    let live = std::cell::RefCell::new(Vec::new());
    let triggers = xmlize(&dioxus_ssr::render_element(body(ast, &surface, domains, true, &live, Some(false))));
    let units = xmlize(&dioxus_ssr::render_element(body(ast, &surface, domains, true, &live, Some(true))));
    let billboard = xmlize(&dioxus_ssr::render_element(body(ast, &surface, domains, false, &live, None)));
    let nouns = xmlize(&dioxus_ssr::render_element(nouns_body(ast, domains, &live)));

    let sorted_set = |iter: &mut dyn Iterator<Item = String>| -> Vec<String> {
        iter.collect::<std::collections::BTreeSet<_>>().into_iter().collect()
    };
    let objectives = sorted_set(&mut ast.files.iter().flat_map(|f| f.objectives.iter().cloned()));
    let unit_names = sorted_set(&mut ast.files.iter().flat_map(|f| f.unit_defs.iter().cloned()));
    let groups = sorted_set(&mut ast.files.iter().flat_map(|f| f.group_defs.iter().cloned()));
    let objective_count = objectives.len();
    let objectives_len = objectives.len();
    let unit_names_len = unit_names.len();
    let vocabulary = Vocabulary {
        conditions: surface.conditions.clone(),
        effects: surface.effects.clone(),
        objectives,
        units: domains.units.clone(),
        unit_names,
        groups,
    };
    let trigger_files = ast.files.iter().filter(|f| !is_roster(&f.path)).count();
    let spawn_count: usize = ast
        .files
        .iter()
        .filter(|f| is_roster(&f.path))
        .flat_map(|f| f.groups.iter())
        .map(|g| g.triggers.len())
        .sum();
    let trigger_count: usize = ast
        .files
        .iter()
        .filter(|f| !is_roster(&f.path))
        .flat_map(|f| f.groups.iter())
        .map(|g| g.triggers.len())
        .sum();
    let form = [
        format!("<div class=\"me-view\" data-view=\"mission\">{}{}</div>",
            crumb(scope),
            summary(trigger_count, spawn_count, objectives_len, unit_names_len, surface.modules.len())),
        section(
            "mission",
            "Triggers",
            &format!("{trigger_count} in {trigger_files} file{}", plural(trigger_files)),
            true,
            &triggers,
        ),
        section(
            "units",
            "Units",
            &format!("{spawn_count} spawn{}", plural(spawn_count)),
            true,
            &units,
        ),
        section(
            "nouns",
            "Nouns",
            &format!(
                "{objective_count} objective{} · {unit_names_len} named unit{}",
                plural(objective_count),
                plural(unit_names_len)
            ),
            true,
            &nouns,
        ),
        section(
            "graph",
            "Graph",
            &format!("{} module{}", surface.modules.len(), plural(surface.modules.len())),
            true,
            &modules_graph(&surface.modules),
        ),
        section(
            "modules",
            "Modules",
            &format!("{} publishing a DSL surface", surface.modules.len()),
            true,
            &modules_body(&surface.modules),
        ),
    ]
    .concat();

    ViewArtifact {
        generation: ast.generation,
        first_file: ast.files.first().map(|f| f.path.clone()),
        form,
        billboard,
        modals: modals(&surface),
        live: live.into_inner(),
        vocabulary,
    }
}

/// The module explorer: what the mission's vocabulary is made of. Each row is
/// a module that publishes a marked surface — its verbs, its mode presets,
/// and what it requires. Rows jump to the module's own types file.
/// The dependency graph as the Reference's overview: modules laid out by
/// depth (what nothing depends on sits at the left), each showing what it
/// requires. No SVG in the RML intersection — the layering IS the drawing.
/// Which module published a verb's root namespace. Identity is the module
/// NAME, not a colour: eight modules cannot be told apart by hue (the
/// categorical palette fails all-pairs CVD past three), so selection
/// highlights and labels carry it instead.
fn module_owner<'a>(root: &str, surface: &'a Surface) -> Option<&'a str> {
    // A call arrives either bare ("Objective") or dotted
    // ("MatchFlow.Started"), and a module publishes the dotted form. Compare
    // namespaces, which is the part that identifies the owner either way.
    let root = root.split('.').next().unwrap_or(root);
    surface
        .modules
        .iter()
        .find(|m| {
            m.conditions
                .iter()
                .chain(m.effects.iter())
                .chain(m.nouns.iter())
                .any(|v| v.split('.').next() == Some(root))
                || m.statements.iter().any(|st| st.name == root)
        })
        .map(|m| m.name.as_str())
}

/// The module a step belongs to, from the verb it invokes. The card view
/// renders steps as phrases rather than calls, so the row carries the
/// attribution: selecting a module has to light up "the mission has started"
/// as readily as `MatchFlow.Started()`.
fn step_owner<'a>(step: &Step, surface: &'a Surface) -> Option<&'a str> {
    step.args
        .iter()
        .find_map(|arg| match arg {
            Value::Verb { path, .. } => module_owner(path, surface),
            _ => None,
        })
        // Steps whose args are literals (.At(0.5, 0.5)) are identified by the
        // statement they belong to instead.
        .or_else(|| {
            surface
                .modules
                .iter()
                .find(|m| {
                    m.statements
                        .iter()
                        .any(|st| {
                            // Statement steps are published dotted (".At").
                            st.name == step.verb
                                || st.steps.iter().any(|s| s.trim_start_matches('.') == step.verb)
                        })
                })
                .map(|m| m.name.as_str())
        })
}

fn modules_graph(modules: &[ModuleInfo]) -> String {
    use std::collections::HashMap;
    let known: Vec<&str> = modules.iter().map(|m| m.name.as_str()).collect();
    let requires: HashMap<&str, Vec<&str>> = modules
        .iter()
        .map(|m| {
            let deps = m
                .requires
                .iter()
                .map(String::as_str)
                .filter(|d| known.contains(d))
                .collect();
            (m.name.as_str(), deps)
        })
        .collect();
    // Depth = longest path to a module that requires nothing (cycle-safe).
    fn depth<'a>(
        name: &'a str,
        requires: &HashMap<&'a str, Vec<&'a str>>,
        seen: &mut Vec<&'a str>,
    ) -> usize {
        if seen.contains(&name) {
            return 0;
        }
        seen.push(name);
        let d = requires
            .get(name)
            .map(|deps| deps.iter().map(|d| depth(d, requires, seen) + 1).max().unwrap_or(0))
            .unwrap_or(0);
        seen.pop();
        d
    }
    let mut rows: Vec<(usize, &ModuleInfo)> = modules
        .iter()
        .map(|m| (depth(&m.name, &requires, &mut Vec::new()), m))
        .collect();
    rows.sort_by(|a, b| (a.0, &a.1.name).cmp(&(b.0, &b.1.name)));

    // Three readings of the same set. Flat is the default because most of the
    // time the question is "what is here"; the diagram answers "what rests on
    // what"; the mermaid source is for pasting where mermaid renders (a PR
    // body, a design doc). The diagram is drawn here rather than by a client
    // library so it needs no network and works in a sandboxed webview.
    let mut out = String::from(
        "<div class=\"me-graph-modes\">\
         <button class=\"me-graph-mode me-graph-mode-on\" data-graph-mode=\"flat\">Flat</button>\
         <button class=\"me-graph-mode\" data-graph-mode=\"graph\">Graph</button></div>",
    );

    // --- flat: the roll-call ------------------------------------------------
    out.push_str("<div class=\"me-graph me-graph-flat\" data-graph-pass=\"flat\">");
    for &(_, m) in rows.iter() {
        let deps = requires.get(m.name.as_str()).cloned().unwrap_or_default();
        let arrows = if deps.is_empty() {
            String::new()
        } else {
            let chips: String = deps
                .iter()
                .map(|d| format!("<span class=\"me-chip me-chip-req\">{d}</span>"))
                .collect();
            format!("<span class=\"me-graph-arrow\">needs</span>{chips}")
        };
        out.push_str(&format!(
            "<div class=\"me-graph-row\">\
             <button class=\"me-chip me-chip-stmt me-graph-node\" data-select-module=\"{}\">{}</button>\
             {arrows}</div>",
            m.name, m.name
        ));
    }
    out.push_str("</div>");

    // --- graph: nodes and edges ---------------------------------------------
    // Layered by dependency depth, then ordered within each layer by the mean
    // position of what it connects to (a barycentre sweep). Without that the
    // rows keep their alphabetical order and the edges cross for no reason.
    const COL: usize = 176;
    const ROW: usize = 52;
    const W: usize = 132;
    const H: usize = 30;

    let mut layers: Vec<Vec<&str>> = Vec::new();
    for &(d, m) in rows.iter() {
        while layers.len() <= d {
            layers.push(Vec::new());
        }
        layers[d].push(m.name.as_str());
    }
    // Order within each layer to reduce crossings. A barycentre sweep can make
    // a layout worse as easily as better, so sweep both directions and keep the
    // best ordering seen — never worse than the alphabetical start.
    let edges: Vec<(&str, &str)> = rows
        .iter()
        .flat_map(|(_, m)| {
            requires
                .get(m.name.as_str())
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .map(move |d| (m.name.as_str(), d))
        })
        .collect();
    let crossings = |layers: &Vec<Vec<&str>>| -> usize {
        let at: HashMap<&str, (usize, usize)> = layers
            .iter()
            .enumerate()
            .flat_map(|(d, l)| l.iter().enumerate().map(move |(i, n)| (*n, (d, i))))
            .collect();
        let mut count = 0;
        for (i, (a, b)) in edges.iter().enumerate() {
            for (c, d) in edges.iter().skip(i + 1) {
                let (Some(&pa), Some(&pb), Some(&pc), Some(&pd)) =
                    (at.get(a), at.get(b), at.get(c), at.get(d))
                else {
                    continue;
                };
                // Only edges spanning the same pair of layers can cross.
                if pa.0 == pc.0 && pb.0 == pd.0 && a != c && b != d {
                    let above = (pa.1 as isize - pc.1 as isize) * (pb.1 as isize - pd.1 as isize);
                    if above < 0 {
                        count += 1;
                    }
                }
            }
        }
        count
    };

    let mut best = layers.clone();
    let mut best_count = crossings(&layers);
    for pass in 0..8 {
        let forward = pass % 2 == 0;
        let at: HashMap<&str, usize> = layers
            .iter()
            .flat_map(|l| l.iter().enumerate().map(|(i, n)| (*n, i)))
            .collect();
        let order: Vec<usize> = if forward {
            (1..layers.len()).collect()
        } else {
            (0..layers.len().saturating_sub(1)).rev().collect()
        };
        for d in order {
            // Barycentre against the neighbouring layer only, which is what
            // makes the sweep converge instead of chasing itself.
            let mut keyed: Vec<(f64, &str)> = layers[d]
                .iter()
                .map(|n| {
                    let mut ns: Vec<usize> = Vec::new();
                    for (a, b) in edges.iter() {
                        if a == n {
                            ns.extend(at.get(b));
                        } else if b == n {
                            ns.extend(at.get(a));
                        }
                    }
                    let k = if ns.is_empty() {
                        at.get(n).copied().unwrap_or(0) as f64
                    } else {
                        ns.iter().map(|i| *i as f64).sum::<f64>() / ns.len() as f64
                    };
                    (k, *n)
                })
                .collect();
            keyed.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal).then(a.1.cmp(b.1)));
            layers[d] = keyed.into_iter().map(|(_, n)| n).collect();
        }
        let c = crossings(&layers);
        if c < best_count {
            best_count = c;
            best = layers.clone();
        }
    }
    let layers = best;

    let mut slot: HashMap<&str, (usize, usize)> = HashMap::new();
    for (d, layer) in layers.iter().enumerate() {
        for (i, name) in layer.iter().enumerate() {
            slot.insert(name, (d, i));
        }
    }
    let width = layers.len() * COL;
    let height = layers.iter().map(Vec::len).max().unwrap_or(1) * ROW + 16;
    let xy = |d: usize, i: usize| (d * COL + 10, i * ROW + 10);

    out.push_str(&format!(
        "<div class=\"me-graph me-graph-graph collapsed\" data-graph-pass=\"graph\">\
         <svg class=\"me-svg\" viewBox=\"0 0 {width} {height}\" width=\"100%\" height=\"{height}\">\
         <defs><marker id=\"me-arrow\" viewBox=\"0 0 8 8\" refX=\"7\" refY=\"4\" \
         markerWidth=\"7\" markerHeight=\"7\" orient=\"auto\">\
         <path d=\"M0,0 L8,4 L0,8 z\" class=\"me-svg-head\"/></marker></defs>"
    ));
    // Curved so parallel runs separate instead of overlapping into one line.
    for &(_, m) in rows.iter() {
        let (d, i) = slot[m.name.as_str()];
        let (x, y) = xy(d, i);
        for dep in requires.get(m.name.as_str()).cloned().unwrap_or_default() {
            if let Some(&(dd, di)) = slot.get(dep) {
                let (dx, dy) = xy(dd, di);
                let (x1, y1) = (x as f64, (y + H / 2) as f64);
                let (x2, y2) = ((dx + W) as f64, (dy + H / 2) as f64);
                let bend = ((x1 - x2).abs() * 0.45).max(26.0);
                out.push_str(&format!(
                    "<path class=\"me-svg-edge\" marker-end=\"url(#me-arrow)\" \
                     d=\"M{x1:.0},{y1:.0} C{:.0},{y1:.0} {:.0},{y2:.0} {x2:.0},{y2:.0}\"/>",
                    x1 - bend,
                    x2 + bend
                ));
            }
        }
    }
    for &(_, m) in rows.iter() {
        let (d, i) = slot[m.name.as_str()];
        let (x, y) = xy(d, i);
        out.push_str(&format!(
            "<g class=\"me-svg-node\" data-select-module=\"{name}\">\
             <rect x=\"{x}\" y=\"{y}\" width=\"{W}\" height=\"{H}\" rx=\"6\"/>\
             <text x=\"{tx}\" y=\"{ty}\">{name}</text></g>",
            name = m.name,
            tx = x + W / 2,
            ty = y + H / 2 + 4
        ));
    }
    // The mermaid source rides along for the copy button rather than taking a
    // tab of its own: it is something you paste elsewhere, not something to read here.
    let mut mermaid = String::from("graph LR\n");
    for &(_, m) in rows.iter() {
        let deps = requires.get(m.name.as_str()).cloned().unwrap_or_default();
        if deps.is_empty() {
            mermaid.push_str(&format!("  {}\n", m.name));
        }
        for dep in deps {
            mermaid.push_str(&format!("  {} --&gt; {}\n", m.name, dep));
        }
    }
    out.push_str(&format!(
        "</svg><button class=\"me-copy-mermaid\" data-copy-mermaid=\"{}\">Copy as mermaid</button></div>",
        mermaid.replace('"', "&quot;").replace('\n', "&#10;")
    ));
    out
}

fn modules_body(modules: &[ModuleInfo]) -> String {
    // The module editor's own path: `modules > N publishing a surface`, the
    // root toggling a picker that jumps to a module — the same shape the
    // mission crumb has, so both editors navigate the same way.
    let mut out = format!(
        "<div class=\"me-crumb\">\
         <button class=\"me-crumb-root\" data-nav=\"modules\">modules</button>\
         <span class=\"me-crumb-sep\">\u{25b8}</span>\
         <span class=\"me-crumb-here\">{} publishing a surface</span></div>",
        modules.len()
    );
    if !modules.is_empty() {
        out.push_str("<div class=\"me-module-list collapsed\" data-module-list=\"1\">");
        for m in modules {
            out.push_str(&format!(
                "<button class=\"me-mission-row\" data-select-module=\"{}\">{}</button>",
                m.name, m.name
            ));
        }
        out.push_str("</div>");
    }
    for m in modules {
        out.push_str(&format!(
            "<div class=\"me-module\" data-module=\"{}\"><div class=\"me-module-head\">\
             <span class=\"me-module-name\">{}</span>\
             <span class=\"me-module-desc\">{}</span></div>",
            m.name, m.name, m.description
        ));
        // Statements first, each with the steps that chain onto it.
        for statement in &m.statements {
            out.push_str(&format!(
                "<div class=\"me-module-row\"><span class=\"me-module-key\">statement</span>\
                 <span class=\"me-chip me-chip-stmt\">{}</span>",
                statement.name
            ));
            for step in &statement.steps {
                out.push_str(&format!("<span class=\"me-chip me-chip-build\">{step}</span>"));
            }
            out.push_str("</div>");
        }
        for (key, class, items) in [
            ("conditions", "me-chip", &m.conditions),
            ("effects", "me-chip me-chip-effect", &m.effects),
            ("nouns", "me-chip me-chip-noun", &m.nouns),
            ("modes", "me-chip me-chip-mode", &m.modes),
            ("requires", "me-chip me-chip-req", &m.requires),
        ] {
            if items.is_empty() {
                continue;
            }
            out.push_str(&format!(
                "<div class=\"me-module-row\"><span class=\"me-module-key\">{key}</span>"
            ));
            for item in items.iter() {
                out.push_str(&format!("<span class=\"{class}\">{item}</span>"));
            }
            out.push_str("</div>");
        }
        out.push_str("</div>");
    }
    out
}

/// The landing dashboard: a KPI row that is also the navigation, plus one
/// part-to-whole bar of the mission's statements. Every tile opens its
/// section — including Modules, the way into the module editor — so the panel
/// can open fully collapsed and still show the shape of the mission.
///
/// Marks follow the viz rules: two categorical slots (blue/orange, validated
/// against both terminals' dark surfaces), a 2px surface gap between
/// segments, rounded ends, and identity carried by the dots — labels and
/// values stay in text ink, never in a series color.
fn summary(triggers: usize, spawns: usize, objectives: usize, named: usize, modules: usize) -> String {
    let total = triggers + spawns;
    let pct = |n: usize| if total == 0 { 0.0 } else { (n as f64) * 100.0 / (total as f64) };
    let tile = |slot: &str, label: &str, value: usize, section: &str| {
        let dot = if slot.is_empty() {
            String::new()
        } else {
            format!("<span class=\"me-stat-dot {slot}\"></span>")
        };
        format!(
            "<button class=\"me-stat\" data-open-section=\"{section}\">{dot}\
             <span class=\"me-stat-label\">{label}</span>\
             <span class=\"me-stat-value\">{value}</span></button>"
        )
    };
    let bar = if total == 0 {
        String::new()
    } else {
        format!(
            "<div class=\"me-propbar\">\
             <div class=\"me-propseg me-series-1\" style=\"width: {:.1}%;\"></div>\
             <div class=\"me-propseg me-series-2\" style=\"width: {:.1}%;\"></div></div>",
            pct(triggers),
            pct(spawns)
        )
    };
    format!(
        "<div class=\"me-summary\"><div class=\"me-stats\">{}{}{}{}{}</div>{bar}</div>",
        tile("me-series-1", "Triggers", triggers, "mission"),
        tile("me-series-2", "Spawns", spawns, "units"),
        tile("", "Objectives", objectives, "nouns"),
        tile("", "Named units", named, "nouns"),
        tile("", "Modules", modules, "modules"),
    )
}

fn plural(n: usize) -> &'static str {
    if n == 1 { "" } else { "s" }
}

/// The navigable path: `missions ▸ <current>`. The root is a button when
/// there are siblings to navigate to; terminals toggle the list and post the
/// pick as a select_mission intent. Names are dir names already restricted to
/// [A-Za-z0-9_-] by serve, so they embed in markup verbatim.
fn crumb(scope: &Scope) -> String {
    let Some(name) = &scope.mission else {
        return String::new();
    };
    let navigable = !scope.missions.is_empty();
    let root = if navigable {
        "<button class=\"me-crumb-root\" data-nav=\"missions\">missions</button>".to_string()
    } else {
        "<span class=\"me-crumb-root\">missions</span>".to_string()
    };
    let mut out = format!(
        "<div class=\"me-crumb\">{root}\
         <span class=\"me-crumb-sep\">\u{25b8}</span>\
         <span class=\"me-crumb-here\">{name}</span></div>"
    );
    if navigable {
        out.push_str("<div class=\"me-mission-list collapsed\" data-mission-list=\"1\">");
        for mission in &scope.missions {
            let current = if Some(mission) == scope.mission.as_ref() { " me-mission-current" } else { "" };
            out.push_str(&format!(
                "<button class=\"me-mission-row{current}\" data-select-mission=\"{mission}\">{mission}</button>"
            ));
        }
        out.push_str("</div>");
    }
    out
}

/// Collapsible section shell. Static titles/keys only — bodies are already
/// rendered+escaped. Terminals toggle the `collapsed` class client-side and
/// remember the choice across re-renders.
fn section(key: &str, title: &str, hint: &str, collapsed: bool, body: &str) -> String {
    // The caret span is empty: glyphs are a stylesheet concern (the game
    // font lacks ▾; web draws it via ::before).
    format!(
        "<div class=\"me-section{}\" data-section=\"{key}\">\
         <button class=\"me-section-head\" data-toggle=\"{key}\">\
         <span class=\"me-caret\"></span>\
         <span class=\"me-section-title\">{title}</span>\
         <span class=\"me-section-hint\">{hint}</span>\
         </button>\
         <div class=\"me-section-body\">{body}</div></div>",
        if collapsed { " collapsed" } else { "" }
    )
}

/// The noun explorer: every objective and unit the mission mentions, wired
/// to the same live keys the form chips use.
fn nouns_body(
    ast: &MissionAst,
    domains: &Domains,
    live: &std::cell::RefCell<Vec<LiveProbe>>,
) -> Element {
    let mut objectives: Vec<String> = Vec::new();
    for file in &ast.files {
        for objective in &file.objectives {
            if !objectives.contains(objective) {
                objectives.push(objective.clone());
            }
        }
    }
    objectives.sort();
    {
        // Nouns can name objectives the phrases didn't probe; sample them too.
        let mut live = live.borrow_mut();
        for objective in &objectives {
            let key = format!("obj:{objective}");
            if !live.iter().any(|p| p.key == key) {
                live.push(LiveProbe {
                    key,
                    kind: "objective".into(),
                    unit_def: None,
                    need: None,
                    objective: Some(objective.clone()),
                    unit_name: None,
                    pack: None,
                    trigger: None,
                });
            }
        }
    }
    let units: Vec<LiveProbe> = live
        .borrow()
        .iter()
        .filter(|p| p.kind == "unit_count")
        .cloned()
        .collect();
    // Roster-named units, one row each; prefer the dead-latch chip when a
    // unit has both destroyed and spotted probes.
    let named: Vec<LiveProbe> = {
        let live = live.borrow();
        let mut seen: Vec<String> = Vec::new();
        let mut out: Vec<LiveProbe> = Vec::new();
        for probe in live.iter().filter(|p| p.kind == "unit_dead").chain(live.iter().filter(|p| p.kind == "unit_spotted")) {
            if let Some(name) = &probe.unit_name {
                if !seen.contains(name) {
                    seen.push(name.clone());
                    out.push(probe.clone());
                }
            }
        }
        out
    };
    let unit_label = |name: &str| {
        domains
            .units
            .iter()
            .find(|u| u.value == name)
            .map(|u| u.label.clone())
            .unwrap_or_else(|| name.to_string())
    };
    rsx! {
        div { class: "me-noun-group", "OBJECTIVES" }
        for objective in objectives.iter() {
            div { class: "me-noun",
                span { class: "me-noun-name", "{objective}" }
                span { class: "me-live", "data-live": "obj:{objective}", "–" }
            }
        }
        div { class: "me-noun-group", "UNITS" }
        for probe in units.iter() {
            div { class: "me-noun",
                span { class: "me-noun-name", {unit_label(probe.unit_def.as_deref().unwrap_or_default())} }
                span { class: "me-live", "data-live": "{probe.key}", "–" }
            }
        }
        if !named.is_empty() {
            div { class: "me-noun-group", "NAMED UNITS" }
            for probe in named.iter() {
                div { class: "me-noun",
                    span { class: "me-noun-name", {probe.unit_name.clone().unwrap_or_default()} }
                    span { class: "me-live", "data-live": "{probe.key}", "–" }
                }
            }
        }
    }
}

/// A mission's files split by what they author: roster (units.lua) or
/// triggers. They get their own sections — a spawn list and a rule list are
/// different work, and mixing them buries both.
fn is_roster(path: &str) -> bool {
    path.ends_with("units.lua")
}

fn body<'a>(
    ast: &'a MissionAst,
    surface: &'a Surface,
    domains: &'a Domains,
    editable: bool,
    live: &'a std::cell::RefCell<Vec<LiveProbe>>,
    roster: Option<bool>,
) -> Element {
    let style = if editable { Style::Ui } else { Style::Dsl };
    rsx! {
        for file in ast.files.iter().filter(|f| roster.is_none_or(|r| is_roster(&f.path) == r)) {
            {file_view(file, &Ctx {
                file: &file.path,
                hash: &file.hash,
                editable,
                style,
                surface,
                domains,
                live,
            })}
        }
    }
}

fn file_view(file: &FileAst, ctx: &Ctx) -> Element {
    rsx! {
        // The file header IS the way into the text: clicking it opens the
        // .lua in the editor (the same open-in-editor jump the cards use).
        div {
            class: "me-file me-jump",
            "data-open-file": "{file.path}",
            "data-open-line": "1",
            span { class: "me-file-name", "{file.path}" }
            span { class: "me-file-open", "open" }
        }
        for group in file.groups.iter() {
            if group.label.is_some() {
                div { class: "me-group", {group.label.clone().unwrap_or_default()} }
            }
            for trigger in group.triggers.iter() {
                {trigger_card(trigger, ctx)}
            }
        }
        // Two palettes, one per file kind: trigger vocabulary for trigger
        // files, spawn chains for the roster.
        if ctx.editable && file.path.ends_with("units.lua") && !ctx.surface.spawns.is_empty() {
            div { class: "me-add-row me-add-statement-row",
                button {
                    class: "me-button me-add-btn",
                    "data-add": "spawn",
                    "data-insert": "{file.insert_trigger_at}",
                    "data-file": "{ctx.file}",
                    "data-hash": "{ctx.hash}",
                    "+ add spawn"
                }
            }
        }
        if ctx.editable && !ctx.surface.conditions.is_empty() && !file.path.ends_with("units.lua") {
            div { class: "me-add-row me-add-statement-row",
                button {
                    class: "me-button me-add-btn",
                    "data-add": "statement",
                    "data-insert": "{file.insert_trigger_at}",
                    "data-file": "{ctx.file}",
                    "data-hash": "{ctx.hash}",
                    "+ add statement"
                }
            }
        }
        if !file.opaque.is_empty() {
            div { class: "me-opaque",
                "{file.opaque.len()} unrecognized span(s) — see bar-mission-kit check"
            }
        }
    }
}

fn trigger_card(trigger: &Trigger, ctx: &Ctx) -> Element {
    // Ghost ordinal is the open-in-editor handle; the file header already
    // names the file.
    let ordinal = trigger.id.rsplit(':').next().unwrap_or_default();
    let title = trigger.label.clone().unwrap_or_else(|| format!("#{ordinal}"));
    let addable = ctx.editable
        && !(ctx.surface.conditions.is_empty() && ctx.surface.effects.is_empty())
        && trigger.steps.first().map(|s| s.verb == "When").unwrap_or(false);
    // Whole-card progress. The engine's own "has this fired" is the honest
    // signal — a once-trigger stays fired after its condition goes false, so
    // shading off a live condition would flicker back to unfired. This rides
    // its own attribute rather than data-live because the front-ends write
    // TEXT into a data-live element, which would erase the card.
    // Only the interactive form gets live wiring: the billboard is read-only
    // display notation, and None omits the attribute entirely.
    let fired_key = (ctx.style == Style::Ui).then(|| format!("trigger:{}", trigger.id));
    if let Some(key) = fired_key.clone() {
        let mut live = ctx.live.borrow_mut();
        if !live.iter().any(|p| p.key == key) {
            live.push(LiveProbe {
                key,
                kind: "trigger_fired".into(),
                unit_def: None,
                need: None,
                objective: None,
                unit_name: None,
                pack: None,
                trigger: Some(trigger.id.clone()),
            });
        }
    }
    rsx! {
        div { class: "me-card", "data-fired": fired_key,
            div { class: "me-card-head",
                span {
                    class: "me-card-title me-jump",
                    "data-open-file": "{ctx.file}",
                    "data-open-line": "{trigger.line}",
                    "{title}"
                }
                if addable {
                    button {
                        class: "me-button me-add-btn me-card-add",
                        "data-add": "step",
                        "data-insert-cond": "{trigger.insert_condition_at}",
                        "data-insert-effect": "{trigger.insert_effect_at}",
                        "data-file": "{ctx.file}",
                        "data-hash": "{ctx.hash}",
                        "+"
                    }
                }
                if ctx.editable {
                    button {
                        class: "me-button me-x me-card-x",
                        "data-op": "remove",
                        "data-remove-start": "{trigger.remove_span.0}",
                        "data-remove-end": "{trigger.remove_span.1}",
                        "data-file": "{ctx.file}",
                        "data-hash": "{ctx.hash}",
                        "×"
                    }
                }
            }
            for step in trigger.steps.iter().filter(|s| s.verb != "Register") {
                {step_row(step, ctx)}
            }
        }
    }
}

fn step_row(step: &Step, ctx: &Ctx) -> Element {
    let badge = match step.verb.as_str() {
        "When" | "AndWhen" => "cond",
        "Do" => "effect",
        _ => "mod",
    };
    let verb = step.verb.to_uppercase();
    let pool = match badge {
        "cond" if !ctx.surface.conditions.is_empty() => Some("conditions"),
        "effect" if !ctx.surface.effects.is_empty() => Some("effects"),
        _ => None,
    };
    rsx! {
        // The row is the jump: clicking anywhere outside a control opens the
        // file at this line. No mode, no button — the text is one click away.
        div {
            class: "me-step me-jump",
            "data-open-file": "{ctx.file}",
            "data-open-line": "{step.line}",
            "data-owner": "{step_owner(step, ctx.surface).unwrap_or(\"\")}",
            span { class: "me-step-verb me-verb-{badge}", "{verb}" }
            span { class: "me-step-body",
                if let Some(phrase) = step_phrase_for(&step.verb).filter(|_| ctx.style == Style::Ui) {
                    {step_phrase_view(phrase, &step.args, ctx)}
                } else {
                    {comma_list(step.args.iter().map(|a| arg_view(a, ctx)).collect())}
                }
            }
            {step_live(step, ctx)}
            span { class: "me-step-tools",
                if ctx.editable && pool.is_some() {
                    button {
                        class: "me-button me-x-btn me-swap-btn",
                        "data-pool": pool.unwrap_or_default(),
                        "data-swap-start": "{step.span.0}",
                        "data-swap-end": "{step.span.1}",
                        "data-file": "{ctx.file}",
                        "data-hash": "{ctx.hash}",
                        img { src: "/luaui/images/repeat.png", width: "11", height: "11" }
                    }
                }
                if ctx.editable && step.verb == "Do" {
                    button {
                        class: "me-button me-x",
                        "data-op": "remove",
                        "data-remove-start": "{step.remove_span.0}",
                        "data-remove-end": "{step.remove_span.1}",
                        "data-file": "{ctx.file}",
                        "data-hash": "{ctx.hash}",
                        "×"
                    }
                }
            }
        }
    }
}

/// Sentence templates: schema'd verb shapes read as English; {semantic} slots
/// bind to the annotated leaves underneath.
/// Sentence templates for a whole chain STEP, when the step's arguments only
/// make sense together (`Spawn(UnitDef("corlab"), "gaia")` reads as one
/// clause, not as two comma-separated values). Slots resolve across every
/// argument of the step.
fn step_phrase_for(verb: &str) -> Option<&'static str> {
    // The verb pill already says SPAWN/AT/NAMED/GROUPED — the phrase carries
    // only what the pill cannot.
    match verb {
        "Spawn" => Some("{unit_def_name} for {team_role}"),
        "At" => Some("{fx}, {fz}"),
        "Named" => Some("{unit_name}"),
        "Grouped" => Some("{unit_group}"),
        _ => None,
    }
}

fn phrase_for(key: &str) -> Option<&'static str> {
    match key {
        "Team.Player.Has" => Some("Player has {count} {unit_def_name}"),
        "Objective.IsComplete" => Some("objective {objective_name} is complete"),
        "Objective.Complete" => Some("complete objective {objective_name}"),
        "MatchFlow.Started" => Some("the mission has started"),
        "MatchFlow.Victory" => Some("victory for the player team"),
        "MatchFlow.Defeat" => Some("defeat for the player team"),
        "Unit.IsDestroyed" => Some("{unit_name} is destroyed"),
        "Unit.IsSpotted" => Some("the player has spotted {unit_name}"),
        // The receiving team is not a slot: slots fill from string and number
        // leaves, and a team arrives as a noun path (Team.Player). Every
        // mission hands to the player today, so the sentence says so — a
        // handover to anyone else would read wrong until nouns can fill slots.
        "Transfer.Units" => Some("share group {unit_group} with the player"),
        "Transfer.Give" => Some("give group {unit_group} to the player, mode or no mode"),
        "Combat.Protect" => Some("protect {unit_name}"),
        "Combat.Unprotect" => Some("stop protecting {unit_name}"),
        // {until} is not a literal slot: it renders the Until argument's own
        // sentence (see slot_view).
        "Combat.Protect.Until" => Some("protect {unit_name} until {until}"),
        // Waves. The pack is a noun path (Scavengers.Skirmish), and a noun
        // cannot fill a slot — same limitation Transfer.Units documents above
        // — so these sentences say "the waves" and let the DO row's own
        // module attribution carry which flavor it is. Begin's key depends on
        // which dial came last, because the chain is order-free, so every
        // ending gets the same sentence.
        "Waves.Begin" | "Waves.Begin.Against" | "Waves.Begin.From" | "Waves.Begin.Intensity" => {
            Some("send waves at the player")
        }
        "Waves.Intensify" => Some("set the wave intensity to {wave_intensity}"),
        "Waves.Surge" => Some("send one wave now"),
        "Waves.End" => Some("stop sending waves"),
        "Waves.Spawned" => Some("a wave has spawned"),
        "Waves.Cleared" => Some("a wave has been cleared"),
        "Waves.BossDefeated" => Some("the boss has been defeated"),
        _ => None,
    }
}

/// The condition expression inside a `.Until(...)` invocation, if any.
fn until_arg(value: &Value) -> Option<&Value> {
    match value {
        Value::Verb { calls, .. } => calls
            .iter()
            .find(|c| c.name.as_deref() == Some("Until"))
            .and_then(|c| c.args.first()),
        _ => None,
    }
}

fn phrase_key(path: &str, calls: &[crate::model::Invocation]) -> String {
    let chained = calls.iter().filter_map(|c| c.name.as_deref()).last();
    match chained {
        Some(name) => format!("{path}.{name}"),
        None => path.to_string(),
    }
}

/// Full-UI rendering of one step argument: the sentence with controls in the
/// slots, falling back to display notation for shapes no phrase covers.
fn arg_view(value: &Value, ctx: &Ctx) -> Element {
    if ctx.style == Style::Ui {
        if let Value::Verb { path, calls, .. } = value {
            if let Some(phrase) = phrase_for(&phrase_key(path, calls)) {
                return phrase_view(phrase, value, ctx);
            }
        }
    }
    value_view(value, ctx)
}

/// The step's live-status chip, pulled into the row's status column: the
/// first probe-able phrase among the args wins. The game fills it via
/// state.json; "–" is the game-not-running placeholder.
fn step_live(step: &Step, ctx: &Ctx) -> Element {
    if ctx.style != Style::Ui {
        return rsx! {};
    }
    for arg in &step.args {
        if let Value::Verb { path, calls, .. } = arg {
            if let Some(probe) = probe_for(&phrase_key(path, calls), arg) {
                {
                    let mut live = ctx.live.borrow_mut();
                    if !live.iter().any(|p| p.key == probe.key) {
                        live.push(probe.clone());
                    }
                }
                return rsx! {
                    span { class: "me-live me-step-live", "data-live": "{probe.key}", "–" }
                };
            }
        }
    }
    rsx! {}
}

fn probe_for(phrase_key: &str, value: &Value) -> Option<LiveProbe> {
    match phrase_key {
        "Team.Player.Has" => {
            let unit = find_semantic_leaf(value, "unit_def_name");
            let count = find_semantic_leaf(value, "count");
            match (unit, count) {
                (Some(Value::String { value: unit, .. }), Some(Value::Number { value: need, .. })) => {
                    Some(LiveProbe {
                        key: format!("unit:{unit}:{}", fmt_num(*need)),
                        kind: "unit_count".into(),
                        unit_def: Some(unit.clone()),
                        need: Some(*need),
                        objective: None,
                        unit_name: None,
                        pack: None,
                        trigger: None,
                    })
                }
                _ => None,
            }
        }
        "Objective.IsComplete" | "Objective.Complete" => {
            match find_semantic_leaf(value, "objective_name") {
                Some(Value::String { value: objective, .. }) => Some(LiveProbe {
                    key: format!("obj:{objective}"),
                    kind: "objective".into(),
                    unit_def: None,
                    need: None,
                    objective: Some(objective.clone()),
                    unit_name: None,
                    pack: None,
                    trigger: None,
                }),
                _ => None,
            }
        }
        "Unit.IsDestroyed" | "Unit.IsSpotted" => {
            let (prefix, kind) = if phrase_key == "Unit.IsDestroyed" {
                ("unitdead", "unit_dead")
            } else {
                ("unitspotted", "unit_spotted")
            };
            match find_semantic_leaf(value, "unit_name") {
                Some(Value::String { value: name, .. }) => Some(LiveProbe {
                    key: format!("{prefix}:{name}"),
                    kind: kind.into(),
                    unit_def: None,
                    need: None,
                    objective: None,
                    unit_name: Some(name.clone()),
                    pack: None,
                    trigger: None,
                }),
                _ => None,
            }
        }
        // Wave conditions are all counters against one director. The pack is
        // a bare reference (`Scavengers.Skirmish`), and lowercasing it gives
        // the name the director publishes its counters under — a mission
        // names a pack and never learns a flavor's rulesparam prefix.
        "Waves.Spawned" | "Waves.Cleared" | "Waves.BossDefeated" => {
            let pack = find_name_ref(value)?.to_ascii_lowercase();
            let kind = match phrase_key {
                "Waves.Spawned" => "waves_spawned",
                "Waves.Cleared" => "waves_cleared",
                _ => "waves_boss_defeated",
            };
            // The count is optional in the DSL and defaults to one.
            let need = match find_semantic_leaf(value, "count") {
                Some(Value::Number { value: need, .. }) => *need,
                _ => 1.0,
            };
            Some(LiveProbe {
                key: format!("{kind}:{pack}:{}", fmt_num(need)),
                kind: kind.into(),
                unit_def: None,
                need: Some(need),
                objective: None,
                unit_name: None,
                pack: Some(pack),
                trigger: None,
            })
        }
        // The Protect row's chip tracks its lifetime bound: delegate to the
        // Until condition's own probe.
        "Combat.Protect.Until" => {
            let arg = until_arg(value)?;
            if let Value::Verb { path, calls, .. } = arg {
                probe_for(&self::phrase_key(path, calls), arg)
            } else {
                None
            }
        }
        _ => None,
    }
}

enum Seg<'p> {
    Text(&'p str),
    Slot(&'p str),
}

/// Split a phrase into literal text and {semantic} slots.
fn phrase_segments(phrase: &str) -> Vec<Seg<'_>> {
    let mut segs = Vec::new();
    let mut rest = phrase;
    while let Some(open) = rest.find('{') {
        if open > 0 {
            segs.push(Seg::Text(&rest[..open]));
        }
        match rest[open..].find('}') {
            Some(close) => {
                segs.push(Seg::Slot(&rest[open + 1..open + close]));
                rest = &rest[open + close + 1..];
            }
            None => {
                rest = &rest[open..];
                break;
            }
        }
    }
    if !rest.is_empty() {
        segs.push(Seg::Text(rest));
    }
    segs
}

fn phrase_view(phrase: &'static str, value: &Value, ctx: &Ctx) -> Element {
    let segs = phrase_segments(phrase);
    rsx! {
        for seg in segs.into_iter() {
            match seg {
                Seg::Text(text) => rsx! { "{text}" },
                Seg::Slot(semantic) => slot_view(value, semantic, ctx),
            }
        }
    }
}

/// Render a step-level phrase: slots resolve against the step's whole
/// argument list, so a slot may come from any argument.
fn step_phrase_view(phrase: &'static str, args: &[Value], ctx: &Ctx) -> Element {
    let segs = phrase_segments(phrase);
    rsx! {
        for seg in segs.into_iter() {
            match seg {
                Seg::Text(text) => rsx! { "{text}" },
                Seg::Slot(semantic) => {
                    match args.iter().find(|a| find_semantic_leaf(a, semantic).is_some()) {
                        Some(arg) => slot_view(arg, semantic, ctx),
                        None => rsx! { span { class: "me-lit", "?" } },
                    }
                }
            }
        }
    }
}

fn slot_view(value: &Value, semantic: &str, ctx: &Ctx) -> Element {
    // The nested-condition slot: render the Until argument as its own
    // sentence (recursively phrased), not as a literal control.
    if semantic == "until" {
        if let Some(arg) = until_arg(value) {
            return arg_view(arg, ctx);
        }
    }
    let leaf = find_semantic_leaf(value, semantic);
    if let Some(leaf) = leaf {
        if let Some(control) = control_for(leaf, ctx) {
            return control;
        }
        let text = match leaf {
            Value::Number { value, .. } => fmt_num(*value),
            Value::String { value, .. } => value.clone(),
            _ => String::new(),
        };
        return rsx! { span { class: "me-lit", "{text}" } };
    }
    let missing = format!("{{{semantic}}}");
    rsx! { "{missing}" }
}

/// The first bare dotted reference among a verb's arguments — the shape a
/// noun contributed by another module takes (`Scavengers.Skirmish`).
fn find_name_ref(value: &Value) -> Option<&str> {
    match value {
        Value::Name { path, .. } => Some(path.as_str()),
        Value::Verb { calls, .. } => calls
            .iter()
            .flat_map(|c| c.args.iter())
            .find_map(find_name_ref),
        Value::Table { fields, .. } => fields.iter().find_map(|f| find_name_ref(&f.value)),
        _ => None,
    }
}

fn find_semantic_leaf<'a>(value: &'a Value, semantic: &str) -> Option<&'a Value> {
    match value {
        Value::Number { semantic: Some(s), .. } if s == semantic => Some(value),
        Value::String { semantic: Some(s), .. } if s == semantic => Some(value),
        Value::Verb { calls, .. } => calls
            .iter()
            .flat_map(|c| c.args.iter())
            .find_map(|a| find_semantic_leaf(a, semantic)),
        Value::Table { fields, .. } => fields
            .iter()
            .find_map(|f| find_semantic_leaf(&f.value, semantic)),
        _ => None,
    }
}

/// Display notation: a Value node back as DSL text; editable literals become
/// controls in place.
fn value_view(value: &Value, ctx: &Ctx) -> Element {
    if let Some(control) = control_for(value, ctx) {
        return control;
    }
    match value {
        Value::Number { value, .. } => {
            let text = fmt_num(*value);
            rsx! { span { class: "me-lit", "{text}" } }
        }
        Value::String { value, .. } => rsx! { span { class: "me-lit", "\"{value}\"" } },
        Value::Boolean { value, .. } => rsx! { span { class: "me-lit", "{value}" } },
        Value::Name { path, .. } => rsx! { span { class: "me-ref", "{path}" } },
        Value::Verb { path, calls, .. } => {
            let owner = module_owner(path, ctx.surface).unwrap_or("");
            rsx! {
            span { class: "me-verb", "data-owner": "{owner}", "{path}" }
            for call in calls.iter() {
                if call.name.is_some() {
                    "."
                    span { class: "me-verb", {call.name.clone().unwrap_or_default()} }
                }
                "("
                {comma_list(call.args.iter().map(|a| value_view(a, ctx)).collect())}
                ")"
            }
            }
        }
        Value::Table { fields, .. } => rsx! {
            "{{ "
            for (i, field) in fields.iter().enumerate() {
                if i > 0 { ", " }
                "{field.key} = "
                {value_view(&field.value, ctx)}
            }
            " }}"
        },
        Value::Opaque { reason, .. } => rsx! { span { class: "me-opaque", "[{reason}]" } },
    }
}

/// The control for one literal leaf, chosen by the semantic the annotator
/// stamped: unit_def_name -> unit dropdown, objective_name -> objective
/// field, number -> number field, plain string -> text field.
fn control_for(value: &Value, ctx: &Ctx) -> Option<Element> {
    if !ctx.editable {
        return None;
    }
    match value {
        Value::String { value, span, semantic } => match semantic.as_deref() {
            // A literal-union parameter type renders as a picker of exactly
            // its literals — the enum came from the LuaCATS alias.
            Some(semantic) if ctx.surface.enums.contains_key(semantic) => {
                Some(enum_select(value, &ctx.surface.enums[semantic], *span, ctx))
            }
            Some("unit_def_name") => Some(unit_select(value, *span, ctx)),
            Some("objective_name") => Some(text_input(value, *span, ctx, "me-input me-input-obj")),
            _ if !value.contains('"') => Some(text_input(value, *span, ctx, "me-input")),
            _ => None,
        },
        Value::Number { value, span, .. } => Some(number_input(*value, *span, ctx)),
        _ => None,
    }
}

fn enum_select(current: &str, options: &[String], span: Span, ctx: &Ctx) -> Element {
    let known = options.iter().any(|o| o == current);
    rsx! {
        select {
            class: "me-select me-select-enum",
            "data-file": "{ctx.file}",
            "data-start": "{span.0}",
            "data-end": "{span.1}",
            "data-hash": "{ctx.hash}",
            "data-quote": "1",
            if !known {
                option { value: "{current}", "selected": "true", "{current}" }
            }
            for opt in options.iter() {
                option {
                    value: "{opt}",
                    "selected": if opt == current { "true" },
                    "{opt}"
                }
            }
        }
    }
}

fn text_input(value: &str, span: Span, ctx: &Ctx, class: &'static str) -> Element {
    rsx! {
        input {
            r#type: "text",
            class: class,
            value: "{value}",
            "data-file": "{ctx.file}",
            "data-start": "{span.0}",
            "data-end": "{span.1}",
            "data-hash": "{ctx.hash}",
            "data-quote": "1",
        }
    }
}

fn number_input(value: f64, span: Span, ctx: &Ctx) -> Element {
    let text = fmt_num(value);
    rsx! {
        input {
            r#type: "text",
            class: "me-input me-input-num",
            value: "{text}",
            "data-file": "{ctx.file}",
            "data-start": "{span.0}",
            "data-end": "{span.1}",
            "data-hash": "{ctx.hash}",
            "data-quote": "0",
        }
    }
}

fn unit_select(current: &str, span: Span, ctx: &Ctx) -> Element {
    let known = ctx.domains.units.iter().any(|u| u.value == current);
    rsx! {
        select {
            class: "me-select me-select-unit",
            "data-file": "{ctx.file}",
            "data-start": "{span.0}",
            "data-end": "{span.1}",
            "data-hash": "{ctx.hash}",
            "data-quote": "1",
            if !known {
                option { value: "{current}", "selected": "true", "{current}" }
            }
            for unit in ctx.domains.units.iter() {
                option {
                    value: "{unit.value}",
                    "selected": if unit.value == current { "true" },
                    "{unit.label}"
                }
            }
        }
    }
}

fn comma_list(items: Vec<Element>) -> Element {
    rsx! {
        for (i, item) in items.into_iter().enumerate() {
            if i > 0 { ", " }
            {item}
        }
    }
}

fn fmt_num(n: f64) -> String {
    if n.is_finite() && n == n.floor() {
        format!("{}", n as i64)
    } else {
        format!("{n}")
    }
}

fn modals(surface: &Surface) -> Modals {
    let row = |kind: &str, entry: &SurfaceEntry, new_text: String| ModalRow {
        kind: kind.to_string(),
        label: entry.label.clone(),
        new_text,
    };
    let group = |label: &str| ModalRow {
        kind: "group".to_string(),
        label: label.to_string(),
        new_text: String::new(),
    };

    let mut add_step = vec![group("WHEN · more conditions (all must hold)")];
    for c in &surface.conditions {
        add_step.push(row("andwhen", c, format!("\t.When({})\n", c.template)));
    }
    add_step.push(group("DO · effects"));
    for e in &surface.effects {
        add_step.push(row("effect", e, format!("\t.Do({})\n", e.template)));
    }

    let mut add_spawn = vec![group("SPAWN")];
    for sp in &surface.spawns {
        add_spawn.push(row("spawn", sp, sp.template.clone()));
    }

    let mut add_statement = vec![group("STARTS WHEN...")];
    for c in &surface.conditions {
        add_statement.push(row(
            "trigger",
            c,
            format!(
                "\nWhen({})\n\t.Do(Objective(\"new_objective\").Complete())\n",
                c.template
            ),
        ));
    }

    let swap = |entries: &[SurfaceEntry]| {
        entries
            .iter()
            .map(|e| row("swap", e, format!("({})", e.template)))
            .collect()
    };

    Modals {
        add_step: Modal { title: "Add to this trigger".into(), rows: add_step },
        add_statement: Modal { title: "New statement".into(), rows: add_statement },
        add_spawn: Modal { title: "Add a spawn".into(), rows: add_spawn },
        swap_conditions: Modal { title: "Swap condition".into(), rows: swap(&surface.conditions) },
        swap_effects: Modal { title: "Swap effect".into(), rows: swap(&surface.effects) },
    }
}

/// RmlUi's parser is XML: void elements must self-close. dioxus-ssr emits
/// HTML5-style `<input ...>`; close them.
fn xmlize(markup: &str) -> String {
    const VOIDS: [&str; 4] = ["input", "img", "br", "hr"];
    let bytes = markup.as_bytes();
    let mut out = String::with_capacity(markup.len() + 32);
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'<' {
            let rest = &markup[i + 1..];
            let is_void = VOIDS.iter().any(|v| {
                rest.starts_with(v)
                    && rest[v.len()..]
                        .bytes()
                        .next()
                        .map_or(true, |c| c.is_ascii_whitespace() || c == b'>' || c == b'/')
            });
            if is_void {
                let mut j = i;
                let mut quote: Option<u8> = None;
                while j < bytes.len() {
                    let c = bytes[j];
                    match quote {
                        Some(q) if c == q => quote = None,
                        Some(_) => {}
                        None if c == b'"' || c == b'\'' => quote = Some(c),
                        None if c == b'>' => break,
                        None => {}
                    }
                    j += 1;
                }
                let inner = &markup[i..j];
                out.push_str(inner);
                if !inner.trim_end().ends_with('/') {
                    out.push('/');
                }
                out.push('>');
                i = j + 1;
                continue;
            }
        }
        let ch = markup[i..].chars().next().expect("in-bounds char");
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const WIN: &str = r#"
When(Team.Player.Has(UnitDef("armpw"), 3))
	.Do(Objective("build_pawns").Complete())

When(Objective("build_pawns").IsComplete())
	.Do(MatchFlow.Victory(Team.Player))
"#;

    /// The overlay plus a derived palette — the same shape collect_ast builds,
    /// so a test sees what the editor sees rather than the raw overlay.
    fn test_surface() -> serde_json::Value {
        let mut surface: serde_json::Value = serde_json::from_str(crate::MISSION_SURFACE).unwrap();
        let types = crate::types::TypeSurface::builtin();
        let labels: std::collections::BTreeMap<String, String> =
            serde_json::from_value(surface["labels"].clone()).unwrap_or_default();
        for (role, paths) in [
            ("conditions", vec!["MatchFlow.Started", "Team.Player.Has", "Objective.IsComplete",
                                "Unit.IsDestroyed", "Unit.IsSpotted"]),
            ("effects", vec!["Objective.Complete", "Transfer.Units", "Combat.Protect",
                             "MatchFlow.Victory", "MatchFlow.Defeat"]),
        ] {
            let mut entries: Vec<serde_json::Value> = paths
                .iter()
                .filter_map(|p| {
                    types.template_for(p).map(|template| {
                        serde_json::json!({
                            "label": labels.get(*p).cloned().unwrap_or_else(|| (*p).to_string()),
                            "template": template,
                        })
                    })
                })
                .collect();
            if let Some(extra) = surface.get(role).and_then(|v| v.as_array()) {
                entries.extend(extra.iter().cloned());
            }
            surface[role] = serde_json::Value::Array(entries);
        }
        surface
    }

    fn ast() -> MissionAst {
        let rec = crate::recognizer::recognize_file("triggers/win.lua", WIN).unwrap();
        MissionAst {
            version: 1,
            generation: 7,
            files: vec![rec.file],
            surface: test_surface(),
        }
    }

    fn domains() -> Domains {
        Domains {
            units: vec![
                DomainOption { value: "armck".into(), label: "Construction Kbot  [armck]".into() },
                DomainOption { value: "armpw".into(), label: "Pawn  [armpw]".into() },
            ],
        }
    }

    /// XML tag-balance check: what RmlUi's parser must be able to swallow.
    fn assert_wellformed(markup: &str) {
        let mut stack: Vec<String> = Vec::new();
        let bytes = markup.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] != b'<' {
                i += 1;
                continue;
            }
            let closing = bytes.get(i + 1) == Some(&b'/');
            let name_start = if closing { i + 2 } else { i + 1 };
            let mut j = name_start;
            while j < bytes.len() && (bytes[j].is_ascii_alphanumeric() || bytes[j] == b'-') {
                j += 1;
            }
            let name = markup[name_start..j].to_string();
            let mut quote: Option<u8> = None;
            while j < bytes.len() {
                let c = bytes[j];
                match quote {
                    Some(q) if c == q => quote = None,
                    Some(_) => {}
                    None if c == b'"' || c == b'\'' => quote = Some(c),
                    None if c == b'>' => break,
                    None => {}
                }
                j += 1;
            }
            assert!(j < bytes.len(), "unterminated tag <{name}");
            let self_closed = bytes[j - 1] == b'/';
            if closing {
                assert_eq!(stack.pop().as_deref(), Some(name.as_str()), "mismatched </{name}>");
            } else if !self_closed {
                stack.push(name);
            }
            i = j + 1;
        }
        assert!(stack.is_empty(), "unclosed tags: {stack:?}");
    }

    #[test]
    fn the_form_is_wellformed_xml_with_editable_controls() {
        let view = render(&ast(), &domains(), &Scope::default());
        assert_wellformed(&view.form);
        assert!(!view.form.contains("<!--"), "hydration markers leaked");
        assert!(view.form.contains("data-quote=\"0\""), "{}", view.form);
        assert!(view.form.contains("data-start="));
        assert!(view.form.contains("data-hash="));
        assert!(view.form.contains("value=\"armpw\" selected=\"true\""), "{}", view.form);
        assert!(view.form.contains("Construction Kbot"));
        assert!(view.form.contains("Player has "));
        assert_eq!(view.generation, 7);
        assert_eq!(view.first_file.as_deref(), Some("triggers/win.lua"));
    }

    #[test]
    fn the_graph_reads_two_ways_and_defaults_to_flat() {
        let view = render(&ast(), &domains(), &Scope::default());
        for mode in ["flat", "graph"] {
            assert!(view.form.contains(&format!("data-graph-mode=\"{mode}\"")), "no {mode} button");
            assert!(view.form.contains(&format!("data-graph-pass=\"{mode}\"")), "no {mode} pass");
        }
        // Flat is what opens; the diagram and the source are second readings.
        assert!(view.form.contains("me-graph-graph collapsed"));
        assert!(!view.form.contains("me-graph-flat collapsed"));
        // The diagram is drawn here, not by a client library: no network, and
        // it survives a sandboxed webview.
        assert!(view.form.contains("<svg class=\"me-svg\""), "no diagram");
        // Mermaid rides on the copy button rather than a tab of its own.
        assert!(view.form.contains("data-copy-mermaid="), "no copy button");
        assert!(view.form.contains("graph LR"), "no mermaid source");
    }

    #[test]
    fn unit_defs_are_checked_against_what_the_game_published() {
        let ast = ast();
        let domains = |names: &[&str]| Domains {
            units: names
                .iter()
                .map(|n| DomainOption { value: n.to_string(), label: n.to_string() })
                .collect(),
        };
        // No published set is no authority: a headless check must not invent
        // findings for content it cannot see.
        assert!(unknown_unit_defs(&ast, &Domains::default()).is_empty());
        // Published and present.
        assert!(unknown_unit_defs(&ast, &domains(&["armpw"])).is_empty());
        // Published and missing: named, with the file and line to fix.
        let found = unknown_unit_defs(&ast, &domains(&["armcom"]));
        assert_eq!(found.len(), 1, "{found:?}");
        assert!(found[0].message.contains("armpw"), "{}", found[0].message);
        assert!(found[0].line > 0);
    }

    #[test]
    fn the_diagram_orders_layers_to_avoid_crossing_edges() {
        // Alphabetically this crosses: "aa" needs the lower node and "bb" the
        // upper one. A barycentre sweep should swap the second layer. Sweeps
        // can regress as easily as improve, so the layout keeps the best
        // ordering it finds rather than the last.
        let module = |name: &str, req: &[&str]| {
            serde_json::json!({
                "name": name, "description": "", "requires": req,
                "statements": [], "conditions": [], "effects": [], "nouns": [], "modes": [],
            })
        };
        let mut ast = ast();
        ast.surface = serde_json::json!({
            "modules": [
                module("alpha", &[]), module("beta", &[]),
                module("aa", &["beta"]), module("bb", &["alpha"]),
            ],
        });
        let view = render(&ast, &domains(), &Scope::default());
        let mut placed: Vec<(usize, usize, String)> = Vec::new();
        for caps in regex_lite_nodes(&view.form) {
            placed.push(caps);
        }
        let y = |name: &str| placed.iter().find(|(_, _, n)| n == name).map(|(_, y, _)| *y).unwrap();
        let x = |name: &str| placed.iter().find(|(x, _, n)| n == name).map(|(x2, _, _)| *x2).unwrap();
        assert_eq!(x("alpha"), x("beta"), "roots share a column");
        assert_eq!(x("aa"), x("bb"), "dependents share a column");
        // aa needs beta and bb needs alpha, so their vertical order must mirror
        // the roots' order for the edges to run parallel.
        assert_eq!(
            y("aa") > y("bb"),
            y("beta") > y("alpha"),
            "layers are ordered so the edges do not cross: {placed:?}"
        );
    }

    /// The three numbers a node carries in the emitted diagram.
    fn regex_lite_nodes(form: &str) -> Vec<(usize, usize, String)> {
        let mut out = Vec::new();
        for chunk in form.split("<g class=\"me-svg-node\" data-select-module=\"").skip(1) {
            let name = chunk.split('"').next().unwrap_or("").to_string();
            let x = chunk.split("<rect x=\"").nth(1).and_then(|c| c.split('"').next()).and_then(|v| v.parse().ok());
            let y = chunk.split("y=\"").nth(1).and_then(|c| c.split('"').next()).and_then(|v| v.parse().ok());
            if let (Some(x), Some(y)) = (x, y) {
                out.push((x, y, name));
            }
        }
        out
    }

    #[test]
    fn every_step_names_the_module_that_published_its_verb() {
        // Selecting a module lights up its steps, so a step with no owner is
        // one the highlight can never reach. Steps whose args are literals
        // (.At) are attributed through the statement they belong to.
        let mut with_modules = ast();
        with_modules.surface = serde_json::json!({
            "modules": [{
                "name": "demo",
                "description": "",
                "requires": [],
                "statements": [{ "name": "When", "steps": [".Do", ".Once"] }],
                "conditions": ["Team.Player.Has"],
                "effects": ["Objective.Complete"],
                "nouns": [],
                "modes": [],
            }],
            // Surface-level entries are label/template pairs; the module's own
            // lists are the plain names it publishes.
            "conditions": [{ "label": "Player has", "template": "Team.Player.Has(UnitDef(\"armpw\"), 3)" }],
            "effects": [{ "label": "complete", "template": "Objective(\"x\").Complete()" }],
        });
        let view = render(&with_modules, &domains(), &Scope::default());
        assert!(view.form.contains("data-owner=\"demo\""), "{}", view.form);
        assert!(!view.form.contains("data-owner=\"\""), "unattributed step: {}", view.form);
    }

    #[test]
    fn the_form_is_sectioned_with_a_noun_explorer() {
        let view = render(&ast(), &domains(), &Scope::default());
        for key in ["mission", "nouns"] {
            assert!(view.form.contains(&format!("data-section=\"{key}\"")), "missing section {key}");
            assert!(view.form.contains(&format!("data-toggle=\"{key}\"")), "missing toggle {key}");
        }
        assert!(!view.form.contains("data-section=\"surface\""));
        assert!(!view.form.contains(">TRIGGERS<"));
        // WIN opens with a newline, so the chain starts on line 2
        assert!(view.form.contains("me-card-title me-jump"));
        assert!(view.form.contains("data-open-line=\"2\""));
        assert!(view.form.contains("Pawn  [armpw]"));
        assert!(view.form.contains("me-live me-step-live"));
        assert_wellformed(&view.form);
    }

    #[test]
    fn live_probes_are_slotted_and_deduped() {
        let view = render(&ast(), &domains(), &Scope::default());
        assert!(view.form.contains("data-live=\"unit:armpw:3\""), "{}", view.form);
        assert!(view.form.contains("data-live=\"obj:build_pawns\""));
        // Chip probes only: card-level trigger probes are their own channel
        // and are counted by every_trigger_card_can_shade_when_it_fires.
        let chips: Vec<_> = view.live.iter().filter(|p| p.kind != "trigger_fired").collect();
        assert_eq!(chips.len(), 2, "{:?}", chips.iter().map(|p| &p.key).collect::<Vec<_>>());
        let unit = view.live.iter().find(|p| p.kind == "unit_count").unwrap();
        assert_eq!(unit.unit_def.as_deref(), Some("armpw"));
        assert_eq!(unit.need, Some(3.0));
        assert!(!view.billboard.contains("data-live"));
    }

    #[test]
    fn the_billboard_is_readonly_display_notation() {
        let view = render(&ast(), &domains(), &Scope::default());
        assert_wellformed(&view.billboard);
        assert!(!view.billboard.contains("<input"));
        assert!(!view.billboard.contains("<select"));
        assert!(!view.billboard.contains("<button"));
        assert!(view.billboard.contains("me-verb"));
        // dioxus entity-escapes text; RmlUi decodes &quot; back to " on display
        assert!(view.billboard.contains("&quot;build_pawns&quot;"), "{}", view.billboard);
    }

    #[test]
    fn an_unknown_unit_still_renders_as_a_selectable_option() {
        let view = render(&ast(), &Domains::default(), &Scope::default());
        assert!(view.form.contains("value=\"armpw\" selected=\"true\""), "{}", view.form);
    }

    #[test]
    fn the_vocabulary_rides_the_artifact_for_editor_completion() {
        let view = render(&ast(), &domains(), &Scope::default());
        let templates = |entries: &[SurfaceEntry]| {
            entries.iter().map(|e| e.template.clone()).collect::<Vec<_>>().join("\n")
        };
        let conditions = templates(&view.vocabulary.conditions);
        for verb in ["MatchFlow.Started()", "Team.Player.Has", ".IsComplete()", ".IsDestroyed()", ".IsSpotted("] {
            assert!(conditions.contains(verb), "missing condition template {verb}");
        }
        let effects = templates(&view.vocabulary.effects);
        for verb in [".Complete()", "Transfer.Units(", "Combat.Protect(", ".Until(", "MatchFlow.Victory(", "MatchFlow.Defeat("] {
            assert!(effects.contains(verb), "missing effect template {verb}");
        }
        assert_eq!(view.vocabulary.objectives, vec!["build_pawns".to_string()]);
        assert_eq!(view.vocabulary.units.len(), 2);
    }

    const CM8: &str = r#"
When(MatchFlow.Started())
	.Do(Transfer.Units("outpost_auto", Team.Player))
	.Do(Combat.Protect(Unit("outpost_command_hub"))
		.Until(Objective("find_the_enclave").IsComplete()))

When(Unit("armada_commander").IsDestroyed())
	.Do(Objective("kill_the_commander").Complete())

When(Objective("relieve_the_outpost").IsComplete())
	.When(Unit("tenebrium_device").IsSpotted(Team.Player))
	.Do(Objective("find_the_enclave").Complete())
"#;

    // CM8's pressure file: the pack is a bare reference contributed by another
    // module, which is the shape the wave probes have to read.
    const CM8_WAVES: &str = r#"
When(MatchFlow.Started())
	.Do(Waves.Begin(Scavengers.Skirmish).Against(Team.Player).From(0.85, 0.15).Intensity(0.3))

When(Waves.Cleared(Scavengers.Skirmish, 3))
	.Do(Objective("held_the_line").Complete())

When(Waves.BossDefeated(Scavengers.Horde))
	.Do(MatchFlow.Victory(Team.Player))
"#;

    fn cm8_ast() -> MissionAst {
        let rec = crate::recognizer::recognize_file("triggers/outpost.lua", CM8).unwrap();
        MissionAst {
            version: 1,
            generation: 3,
            files: vec![rec.file],
            surface: test_surface(),
        }
    }

    #[test]
    fn the_combat_vocabulary_renders_as_sentences() {
        let view = render(&cm8_ast(), &domains(), &Scope::default());
        assert_wellformed(&view.form);
        assert!(view.form.contains("the mission has started"), "{}", view.form);
        assert!(view.form.contains("share group "));
        assert!(view.form.contains("protect "));
        assert!(view.form.contains(" until "));
        assert!(view.form.contains("objective "));
        assert!(view.form.contains(" is complete"));
        assert!(view.form.contains(" is destroyed"));
        assert!(view.form.contains("the player has spotted "));
        assert!(!view.form.contains("{unit_name}"), "{}", view.form);
        assert!(!view.form.contains("{until}"), "{}", view.form);
        assert!(!view.form.contains("{unit_group}"), "{}", view.form);
    }

    #[test]
    fn the_roster_renders_with_typed_pickers_and_no_trigger_palette() {
        let roster = "Spawn(UnitDef(\"corlab\"), \"gaia\")\n\t.At(0.42, 0.42)\n\t.Named(\"hub\")\n\t.Grouped(\"outpost\")\n";
        let rec = crate::recognizer::recognize_file("units.lua", roster).unwrap();
        let mut surface: serde_json::Value = test_surface();
        surface["enums"] =
            serde_json::to_value(crate::types::TypeSurface::builtin().enums()).unwrap();
        let ast = MissionAst { version: 1, generation: 1, files: vec![rec.file], surface };
        let view = render(&ast, &domains(), &Scope::default());
        assert_wellformed(&view.form);
        assert!(view.form.contains("me-select-enum"), "{}", view.form);
        for role in ["player", "enemy", "gaia"] {
            assert!(view.form.contains(&format!("value=\"{role}\"")));
        }
        assert!(view.form.contains("value=\"corlab\" selected=\"true\""));
        // The roster takes spawn chains, not trigger vocabulary.
        assert!(view.form.contains("data-add=\"spawn\""), "{}", view.form);
        assert!(!view.form.contains("data-add=\"statement\""), "{}", view.form);
        assert!(view.form.contains("+ add spawn"));
        // Removing a spawn is the same control a trigger card carries.
        assert!(view.form.contains("data-op=\"remove\""), "{}", view.form);
        assert_eq!(view.vocabulary.unit_names, vec!["hub".to_string()]);
        assert_eq!(view.vocabulary.groups, vec!["outpost".to_string()]);
    }

    #[test]
    fn named_unit_probes_are_emitted_and_listed() {
        let view = render(&cm8_ast(), &domains(), &Scope::default());
        let dead = view.live.iter().find(|p| p.kind == "unit_dead").unwrap();
        assert_eq!(dead.key, "unitdead:armada_commander");
        assert_eq!(dead.unit_name.as_deref(), Some("armada_commander"));
        let spotted = view.live.iter().find(|p| p.kind == "unit_spotted").unwrap();
        assert_eq!(spotted.key, "unitspotted:tenebrium_device");
        assert!(view.live.iter().any(|p| p.key == "obj:find_the_enclave"));
        assert!(view.form.contains("data-live=\"obj:find_the_enclave\""));
        assert!(view.form.contains(">NAMED UNITS<"));
        assert!(view.form.contains("armada_commander"));
    }

    #[test]
    fn wave_probes_name_the_director_the_mission_named() {
        let rec = crate::recognizer::recognize_file("triggers/waves.lua", CM8_WAVES).unwrap();
        let ast = MissionAst {
            version: 1,
            generation: 3,
            files: vec![rec.file],
            surface: test_surface(),
        };
        let view = render(&ast, &domains(), &Scope::default());
        assert_wellformed(&view.form);

        // The pack is written `Scavengers.Skirmish`; the director publishes
        // under `scavengers.skirmish`, and the probe has to bridge the two —
        // a mission never learns a flavor's rulesparam prefix.
        let cleared = view.live.iter().find(|p| p.kind == "waves_cleared").unwrap();
        assert_eq!(cleared.pack.as_deref(), Some("scavengers.skirmish"));
        assert_eq!(cleared.need, Some(3.0));
        assert_eq!(cleared.key, "waves_cleared:scavengers.skirmish:3");

        // The count is optional in the DSL and means one.
        let boss = view.live.iter().find(|p| p.kind == "waves_boss_defeated").unwrap();
        assert_eq!(boss.pack.as_deref(), Some("scavengers.horde"));
        assert_eq!(boss.need, Some(1.0));

        // And the chips are slotted into the form the game fills in.
        assert!(view.form.contains("data-live=\"waves_cleared:scavengers.skirmish:3\""), "{}", view.form);
    }

    #[test]
    fn every_trigger_card_can_shade_when_it_fires() {
        let view = render(&cm8_ast(), &domains(), &Scope::default());
        let fired: Vec<_> = view.live.iter().filter(|p| p.kind == "trigger_fired").collect();
        assert_eq!(fired.len(), 3, "one probe per trigger card");

        // The id is the runtime's own identity minus the mission prefix the
        // game adds back, so the bridge can compose it without the kit ever
        // knowing which mission it is editing.
        let first = fired.iter().find(|p| p.trigger.as_deref() == Some("triggers/outpost.lua:1"));
        assert!(first.is_some(), "{:?}", fired.iter().map(|p| &p.trigger).collect::<Vec<_>>());

        // It rides its own attribute: a data-live element gets TEXT written
        // into it, which would erase the card. The name deliberately does not
        // contain "data-live" either — the billboard asserts on that substring.
        assert!(view.form.contains("data-fired=\"trigger:triggers/outpost.lua:1\""), "{}", view.form);
        assert!(!view.form.contains("data-live=\"trigger:"), "cards must not use the text channel");
        assert!(!view.billboard.contains("data-fired"), "the billboard carries no live wiring");
        assert_wellformed(&view.form);
    }

    #[test]
    fn the_waves_vocabulary_renders_as_sentences() {
        let rec = crate::recognizer::recognize_file("triggers/waves.lua", CM8_WAVES).unwrap();
        let ast = MissionAst {
            version: 1,
            generation: 3,
            files: vec![rec.file],
            surface: test_surface(),
        };
        let view = render(&ast, &domains(), &Scope::default());
        assert_wellformed(&view.form);

        assert!(view.form.contains("send waves at the player"), "{}", view.form);
        assert!(view.form.contains("a wave has been cleared"), "{}", view.form);
        assert!(view.form.contains("the boss has been defeated"), "{}", view.form);

        // Raw call notation is the fallback for shapes no phrase covers, so
        // its presence here means a phrase key stopped matching. That is how
        // this shipped once: the chain is order-free, so Begin's key is
        // whichever dial came last.
        assert!(!view.form.contains("Waves.Begin("), "{}", view.form);
        assert!(!view.form.contains("Waves.Surge("), "{}", view.form);
        assert!(!view.form.contains("Waves.End("), "{}", view.form);
    }

    #[test]
    fn modal_rows_carry_composed_edits() {
        let view = render(&ast(), &domains(), &Scope::default());
        let step = &view.modals.add_step;
        assert!(step.rows.iter().any(|r| r.kind == "andwhen" && r.new_text.starts_with("\t.When(")));
        assert!(step.rows.iter().any(|r| r.kind == "effect" && r.new_text.starts_with("\t.Do(")));
        let statement = &view.modals.add_statement;
        assert!(statement.rows.iter().any(|r| r.kind == "trigger"
            && r.new_text.starts_with("\nWhen(")
            && r.new_text.contains(".Do(")));
        assert!(view.modals.swap_conditions.rows.iter().all(|r| r.kind == "swap"
            && r.new_text.starts_with('(')
            && r.new_text.ends_with(')')));
    }

    #[test]
    fn the_breadcrumb_navigates_missions() {
        let scope = Scope {
            mission: Some("cm8_ashfall".into()),
            missions: vec!["cm8_ashfall".into(), "hello_pawns".into()],
        };
        let view = render(&ast(), &domains(), &scope);
        assert_wellformed(&view.form);
        assert!(view.form.contains("data-nav=\"missions\""), "{}", view.form);
        assert!(view.form.contains("me-crumb-here\">cm8_ashfall<"));
        assert!(view.form.contains("data-select-mission=\"hello_pawns\""));
        assert!(view.form.contains("me-mission-row me-mission-current"));
        assert!(view.form.find("me-crumb").unwrap() < view.form.find("me-file").unwrap());
        let pinned = render(
            &ast(),
            &domains(),
            &Scope { mission: Some("solo".into()), missions: vec![] },
        );
        assert!(!pinned.form.contains("data-nav=\"missions\""));
        assert!(!pinned.form.contains("data-select-mission"));
        assert!(pinned.form.contains("me-crumb-here\">solo<"));
        // no scope at all -> no MISSION crumb (the module editor keeps its own)
        let bare = render(&ast(), &domains(), &Scope::default());
        assert!(!bare.form.contains("me-crumb-here\">solo<"));
        assert!(!bare.form.contains("data-select-mission"));
    }

    #[test]
    fn void_elements_self_close() {
        assert_eq!(xmlize("<input value=\"a>b\">"), "<input value=\"a>b\"/>");
        assert_eq!(xmlize("<img src=\"x.png\"/>"), "<img src=\"x.png\"/>");
        assert_eq!(xmlize("<div><input type=\"text\"></div>"), "<div><input type=\"text\"/></div>");
    }
}
