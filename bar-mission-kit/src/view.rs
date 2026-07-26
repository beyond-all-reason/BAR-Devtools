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
}

#[derive(Serialize)]
pub struct Modals {
    pub add_step: Modal,
    pub add_statement: Modal,
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
struct Surface {
    #[serde(default)]
    conditions: Vec<SurfaceEntry>,
    #[serde(default)]
    effects: Vec<SurfaceEntry>,
    /// semantic -> options, derived from literal-union type aliases
    /// (collect_ast merges them into the surface overlay).
    #[serde(default)]
    enums: std::collections::BTreeMap<String, Vec<String>>,
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

pub fn render(ast: &MissionAst, domains: &Domains, scope: &Scope) -> ViewArtifact {
    let surface: Surface = serde_json::from_value(ast.surface.clone()).unwrap_or_default();
    let live = std::cell::RefCell::new(Vec::new());
    let mission = xmlize(&dioxus_ssr::render_element(body(ast, &surface, domains, true, &live)));
    let billboard = xmlize(&dioxus_ssr::render_element(body(ast, &surface, domains, false, &live)));
    let nouns = xmlize(&dioxus_ssr::render_element(nouns_body(ast, domains, &live)));

    let files = ast.files.len();
    let sorted_set = |iter: &mut dyn Iterator<Item = String>| -> Vec<String> {
        iter.collect::<std::collections::BTreeSet<_>>().into_iter().collect()
    };
    let objectives = sorted_set(&mut ast.files.iter().flat_map(|f| f.objectives.iter().cloned()));
    let unit_names = sorted_set(&mut ast.files.iter().flat_map(|f| f.unit_defs.iter().cloned()));
    let groups = sorted_set(&mut ast.files.iter().flat_map(|f| f.group_defs.iter().cloned()));
    let objective_count = objectives.len();
    let unit_count = live.borrow().iter().filter(|p| p.kind == "unit_count").count();
    let vocabulary = Vocabulary {
        conditions: surface.conditions.clone(),
        effects: surface.effects.clone(),
        objectives,
        units: domains.units.clone(),
        unit_names,
        groups,
    };
    let form = [
        section(
            "mission",
            "Mission Editor",
            &format!("{files} file{}", plural(files)),
            false,
            &format!("{}{mission}", crumb(scope)),
        ),
        section(
            "nouns",
            "Nouns",
            &format!(
                "{objective_count} objective{} · {unit_count} unit{}",
                plural(objective_count),
                plural(unit_count)
            ),
            false,
            &nouns,
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
         <span class=\"me-crumb-sep\"></span>\
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

/// The noun explorer: every objective, unit, and trigger the mission
/// mentions, wired to the same live keys the form chips use. Trigger rows
/// are open-in-editor jumps (data-open-*).
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

fn body<'a>(
    ast: &'a MissionAst,
    surface: &'a Surface,
    domains: &'a Domains,
    editable: bool,
    live: &'a std::cell::RefCell<Vec<LiveProbe>>,
) -> Element {
    let style = if editable { Style::Ui } else { Style::Dsl };
    rsx! {
        for file in ast.files.iter() {
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
        div { class: "me-file", "{file.path}" }
        for group in file.groups.iter() {
            if group.label.is_some() {
                div { class: "me-group", {group.label.clone().unwrap_or_default()} }
            }
            for trigger in group.triggers.iter() {
                {trigger_card(trigger, ctx)}
            }
        }
        // The add-statement palette is trigger vocabulary; the roster file's
        // spawn chains don't take it.
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
    let title = trigger.label.clone().unwrap_or_else(|| trigger.id.clone());
    rsx! {
        div { class: "me-card",
            div { class: "me-card-head",
                span {
                    class: "me-card-title me-jump",
                    "data-open-file": "{ctx.file}",
                    "data-open-line": "{trigger.line}",
                    "{title}"
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
            if ctx.editable
                && !(ctx.surface.conditions.is_empty() && ctx.surface.effects.is_empty())
                && trigger.steps.first().map(|s| s.verb == "When").unwrap_or(false)
            {
                div { class: "me-add-row",
                    button {
                        class: "me-button me-add-btn",
                        "data-add": "step",
                        "data-insert-cond": "{trigger.insert_condition_at}",
                        "data-insert-effect": "{trigger.insert_effect_at}",
                        "data-file": "{ctx.file}",
                        "data-hash": "{ctx.hash}",
                        "+ add"
                    }
                }
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
        div { class: "me-step",
            span { class: "me-step-verb me-verb-{badge}", "{verb}" }
            span { class: "me-step-body",
                {comma_list(step.args.iter().map(|a| arg_view(a, ctx)).collect())}
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
        "Units.Transfer" => Some("give group {unit_group} to the player"),
        "Combat.Protect" => Some("protect {unit_name}"),
        // {until} is not a literal slot: it renders the Until argument's own
        // sentence (see slot_view).
        "Combat.Protect.Until" => Some("protect {unit_name} until {until}"),
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
                }),
                _ => None,
            }
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

fn phrase_view(phrase: &'static str, value: &Value, ctx: &Ctx) -> Element {
    enum Seg<'p> {
        Text(&'p str),
        Slot(&'p str),
    }
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
    rsx! {
        for seg in segs.into_iter() {
            match seg {
                Seg::Text(text) => rsx! { "{text}" },
                Seg::Slot(semantic) => slot_view(value, semantic, ctx),
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
        Value::Verb { path, calls, .. } => rsx! {
            span { class: "me-verb", "{path}" }
            for call in calls.iter() {
                if call.name.is_some() {
                    "."
                    span { class: "me-verb", {call.name.clone().unwrap_or_default()} }
                }
                "("
                {comma_list(call.args.iter().map(|a| value_view(a, ctx)).collect())}
                ")"
            }
        },
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

    fn ast() -> MissionAst {
        let rec = crate::recognizer::recognize_file("triggers/win.lua", WIN).unwrap();
        MissionAst {
            version: 1,
            generation: 7,
            files: vec![rec.file],
            surface: serde_json::from_str(crate::MISSION_SURFACE).unwrap(),
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
        // count literal -> number input with span + CAS hash attributes
        assert!(view.form.contains("data-quote=\"0\""), "{}", view.form);
        assert!(view.form.contains("data-start="));
        assert!(view.form.contains("data-hash="));
        // unit literal -> dropdown with the current unit selected
        assert!(view.form.contains("value=\"armpw\" selected=\"true\""), "{}", view.form);
        assert!(view.form.contains("Construction Kbot"));
        // sentence phrase, not raw DSL, in ui style
        assert!(view.form.contains("Player has "));
        assert_eq!(view.generation, 7);
        assert_eq!(view.first_file.as_deref(), Some("triggers/win.lua"));
    }

    #[test]
    fn the_form_is_sectioned_with_a_noun_explorer() {
        let view = render(&ast(), &domains(), &Scope::default());
        for key in ["mission", "nouns"] {
            assert!(view.form.contains(&format!("data-section=\"{key}\"")), "missing section {key}");
            assert!(view.form.contains(&format!("data-toggle=\"{key}\"")), "missing toggle {key}");
        }
        // two sections only: triggers ARE the mission section, API is
        // intellisense's job
        assert!(!view.form.contains("data-section=\"surface\""));
        assert!(!view.form.contains(">TRIGGERS<"));
        // card titles jump to source (WIN opens with a newline: line 2)
        assert!(view.form.contains("me-card-title me-jump"));
        assert!(view.form.contains("data-open-line=\"2\""));
        // noun explorer: human unit label; step chips sit in the status column
        assert!(view.form.contains("Pawn  [armpw]"));
        assert!(view.form.contains("me-live me-step-live"));
        assert_wellformed(&view.form);
    }

    #[test]
    fn live_probes_are_slotted_and_deduped() {
        let view = render(&ast(), &domains(), &Scope::default());
        // unit chip in the sentence + a probe describing what to sample
        assert!(view.form.contains("data-live=\"unit:armpw:3\""), "{}", view.form);
        assert!(view.form.contains("data-live=\"obj:build_pawns\""));
        // build_pawns appears in two triggers -> one probe (content-keyed)
        assert_eq!(view.live.len(), 2, "{:?}", view.live.iter().map(|p| &p.key).collect::<Vec<_>>());
        let unit = view.live.iter().find(|p| p.kind == "unit_count").unwrap();
        assert_eq!(unit.unit_def.as_deref(), Some("armpw"));
        assert_eq!(unit.need, Some(3.0));
        // telemetry never dirties the markup contract: billboard has no chips
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
        // completion offers every verb family the sandbox injects
        let templates = |entries: &[SurfaceEntry]| {
            entries.iter().map(|e| e.template.clone()).collect::<Vec<_>>().join("\n")
        };
        let conditions = templates(&view.vocabulary.conditions);
        for verb in ["MatchFlow.Started()", "Team.Player.Has", ".IsComplete()", ".IsDestroyed()", ".IsSpotted("] {
            assert!(conditions.contains(verb), "missing condition template {verb}");
        }
        let effects = templates(&view.vocabulary.effects);
        for verb in [".Complete()", "Units.Transfer(", "Combat.Protect(", ".Until(", "MatchFlow.Victory(", "MatchFlow.Defeat("] {
            assert!(effects.contains(verb), "missing effect template {verb}");
        }
        // nouns the mission itself defines ride along for slot completion
        assert_eq!(view.vocabulary.objectives, vec!["build_pawns".to_string()]);
        assert_eq!(view.vocabulary.units.len(), 2);
    }

    const CM8: &str = r#"
When(MatchFlow.Started())
	.Do(Units.Transfer("outpost_auto", Team.Player))
	.Do(Combat.Protect(Unit("outpost_command_hub"))
		.Until(Objective("find_the_enclave").IsComplete()))

When(Unit("armada_commander").IsDestroyed())
	.Do(Objective("kill_the_commander").Complete())

When(Objective("relieve_the_outpost").IsComplete())
	.When(Unit("tenebrium_device").IsSpotted(Team.Player))
	.Do(Objective("find_the_enclave").Complete())
"#;

    fn cm8_ast() -> MissionAst {
        let rec = crate::recognizer::recognize_file("triggers/outpost.lua", CM8).unwrap();
        MissionAst {
            version: 1,
            generation: 3,
            files: vec![rec.file],
            surface: serde_json::from_str(crate::MISSION_SURFACE).unwrap(),
        }
    }

    #[test]
    fn the_combat_vocabulary_renders_as_sentences() {
        let view = render(&cm8_ast(), &domains(), &Scope::default());
        assert_wellformed(&view.form);
        assert!(view.form.contains("the mission has started"), "{}", view.form);
        assert!(view.form.contains("give group "));
        assert!(view.form.contains("protect "));
        // the Until slot renders the nested condition's own sentence
        assert!(view.form.contains(" until "));
        assert!(view.form.contains("objective "));
        assert!(view.form.contains(" is complete"));
        assert!(view.form.contains(" is destroyed"));
        assert!(view.form.contains("the player has spotted "));
        // every slot resolved — no literal {semantic} leftovers
        assert!(!view.form.contains("{unit_name}"), "{}", view.form);
        assert!(!view.form.contains("{until}"), "{}", view.form);
        assert!(!view.form.contains("{unit_group}"), "{}", view.form);
    }

    #[test]
    fn the_roster_renders_with_typed_pickers_and_no_trigger_palette() {
        let roster = "Spawn(UnitDef(\"corlab\"), \"gaia\")\n\t.At(0.42, 0.42)\n\t.Named(\"hub\")\n\t.Grouped(\"outpost\")\n";
        let rec = crate::recognizer::recognize_file("units.lua", roster).unwrap();
        let mut surface: serde_json::Value = serde_json::from_str(crate::MISSION_SURFACE).unwrap();
        surface["enums"] =
            serde_json::to_value(crate::types::TypeSurface::builtin().enums()).unwrap();
        let ast = MissionAst { version: 1, generation: 1, files: vec![rec.file], surface };
        let view = render(&ast, &domains(), &Scope::default());
        assert_wellformed(&view.form);
        // the team role renders as a picker of exactly the alias's literals
        assert!(view.form.contains("me-select-enum"), "{}", view.form);
        for role in ["player", "enemy", "gaia"] {
            assert!(view.form.contains(&format!("value=\"{role}\"")));
        }
        // the def slot is the usual unit dropdown
        assert!(view.form.contains("value=\"corlab\" selected=\"true\""));
        // trigger vocabulary stays out of the roster file
        assert!(!view.form.contains("data-add"), "{}", view.form);
        // declared nouns ride the vocabulary for slot completion
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
        // the Protect row's chip delegates to its Until condition
        assert!(view.live.iter().any(|p| p.key == "obj:find_the_enclave"));
        assert!(view.form.contains("data-live=\"obj:find_the_enclave\""));
        // the noun explorer lists roster-named units
        assert!(view.form.contains(">NAMED UNITS<"));
        assert!(view.form.contains("armada_commander"));
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
        // the crumb leads the mission section, before the file view
        assert!(view.form.find("me-crumb").unwrap() < view.form.find("me-file").unwrap());
        // pinned serve (no root): the path shows, nothing navigates
        let pinned = render(
            &ast(),
            &domains(),
            &Scope { mission: Some("solo".into()), missions: vec![] },
        );
        assert!(!pinned.form.contains("data-nav"));
        assert!(!pinned.form.contains("data-select-mission"));
        assert!(pinned.form.contains("me-crumb-here\">solo<"));
        // no scope at all -> no crumb
        let bare = render(&ast(), &domains(), &Scope::default());
        assert!(!bare.form.contains("me-crumb"));
    }

    #[test]
    fn void_elements_self_close() {
        assert_eq!(xmlize("<input value=\"a>b\">"), "<input value=\"a>b\"/>");
        assert_eq!(xmlize("<img src=\"x.png\"/>"), "<img src=\"x.png\"/>");
        assert_eq!(xmlize("<div><input type=\"text\"></div>"), "<div><input type=\"text\"/></div>");
    }
}
