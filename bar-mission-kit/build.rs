//! The built-in type surface is every fixture the sync script drops under
//! fixtures/<module>/types/ — globbed here so adding a module never means
//! editing a list.
use std::{env, fs, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let fixtures = manifest.join("fixtures");
    println!("cargo:rerun-if-changed={}", fixtures.display());

    let mut paths: Vec<PathBuf> =
        glob::glob(&format!("{}/modules/*/types/*.lua", fixtures.display()))
            .unwrap()
            .filter_map(Result::ok)
            .collect();
    paths.sort();

    let mut out = String::from("pub const SNAPSHOTS: &[&str] = &[\n");
    for path in &paths {
        println!("cargo:rerun-if-changed={}", path.display());
        out.push_str(&format!(
            "    include_str!({:?}),\n",
            path.display().to_string()
        ));
    }
    out.push_str("];\n");
    let dest = PathBuf::from(env::var("OUT_DIR").unwrap()).join("snapshots.rs");
    fs::write(dest, out).unwrap();
}
