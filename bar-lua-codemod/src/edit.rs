/// A byte-range replacement against the original source. Transforms collect
/// edits over the CST walk; non-overlapping by construction (each edit spans
/// tokens of a distinct node).
pub struct Edit {
    pub start: usize,
    pub end: usize,
    pub text: String,
}

pub fn apply(source: &str, mut edits: Vec<Edit>) -> String {
    edits.sort_by_key(|e| e.start);
    let mut out = String::with_capacity(source.len());
    let mut pos = 0;
    for e in edits {
        out.push_str(&source[pos..e.start]);
        out.push_str(&e.text);
        pos = e.end;
    }
    out.push_str(&source[pos..]);
    out
}
