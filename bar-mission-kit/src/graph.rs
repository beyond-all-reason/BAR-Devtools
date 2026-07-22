//! Trigger-graph artifact: the mission's dependency structure as GraphViz
//! DOT, derived from the decorated AST. Edges follow objective state:
//! a trigger that Completes an objective feeds every trigger watching
//! IsComplete on it; MatchFlow.Victory/Defeat are terminal nodes. The DSL
//! doc's editor stage 2 (read-only trigger graph) as data — renderers can
//! come later without re-deriving anything.

use crate::model::{MissionAst, Value};

pub fn dot(ast: &MissionAst) -> String {
    let mut nodes = String::new();
    let mut edges = String::new();

    for file in &ast.files {
        for group in &file.groups {
            for trigger in &group.triggers {
                let id = node_id(&trigger.id);
                let label = trigger.label.clone().unwrap_or_else(|| trigger.id.clone());
                nodes.push_str(&format!(
                    "    {id} [label=\"{}\", shape=box];\n",
                    escape(&label)
                ));
                for step in &trigger.steps {
                    for arg in &step.args {
                        scan_value(&id, &step.verb, arg, &mut nodes, &mut edges);
                    }
                }
            }
        }
    }

    format!("digraph mission {{\n    rankdir=LR;\n{nodes}{edges}}}\n")
}

fn scan_value(trigger_id: &str, verb: &str, value: &Value, nodes: &mut String, edges: &mut String) {
    let Value::Verb { path, calls, .. } = value else {
        return;
    };
    if path == "Objective" {
        let Some(name) = calls
            .first()
            .and_then(|c| c.args.first())
            .and_then(|a| match a {
                Value::String { value, .. } => Some(value.clone()),
                _ => None,
            })
        else {
            return;
        };
        let objective = format!("objective_{}", sanitize(&name));
        let chained = calls.iter().filter_map(|c| c.name.as_deref()).next();
        nodes.push_str(&format!(
            "    {objective} [label=\"{}\", shape=ellipse];\n",
            escape(&name)
        ));
        match (verb, chained) {
            (_, Some("Complete")) => {
                edges.push_str(&format!("    {trigger_id} -> {objective};\n"));
            }
            (_, Some("IsComplete")) => {
                edges.push_str(&format!("    {objective} -> {trigger_id};\n"));
            }
            _ => {}
        }
    } else if path == "MatchFlow.Victory" || path == "MatchFlow.Defeat" {
        let terminal = if path.ends_with("Victory") { "VICTORY" } else { "DEFEAT" };
        nodes.push_str(&format!(
            "    {terminal} [shape=doublecircle];\n"
        ));
        edges.push_str(&format!("    {trigger_id} -> {terminal};\n"));
    }
    // nested verb args (e.g. conditions wrapping other verbs)
    for call in calls {
        for arg in &call.args {
            scan_value(trigger_id, verb, arg, nodes, edges);
        }
    }
}

fn node_id(trigger_id: &str) -> String {
    format!("t_{}", sanitize(trigger_id))
}

fn sanitize(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

fn escape(text: &str) -> String {
    text.replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
    #[test]
    fn hello_pawns_graph_has_the_objective_cascade() {
        let source = r#"
T.When(Team.Player.Has(UnitDef("armpw"), 3))
	.Do(Objective("build_pawns").Complete())
	.Register()

T.When(Objective("build_pawns").IsComplete())
	.Do(MatchFlow.Victory(Team.Player))
	.Register()
"#;
        let rec = crate::recognizer::recognize_file("triggers/win.lua", source).unwrap();
        let ast = crate::model::MissionAst { version: 1, generation: 1, files: vec![rec.file] };
        let dot = super::dot(&ast);
        assert!(dot.contains("t_triggers_win_lua_1 -> objective_build_pawns"), "{dot}");
        assert!(dot.contains("objective_build_pawns -> t_triggers_win_lua_2"), "{dot}");
        assert!(dot.contains("t_triggers_win_lua_2 -> VICTORY"), "{dot}");
    }
}
