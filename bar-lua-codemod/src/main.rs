use clap::{Parser, Subcommand};
use full_moon::visitors::VisitorMut;
use std::path::PathBuf;
use std::{fs, process};

mod bracket_to_dot;
mod detach_bar_modules;
mod i18n_kikito;
mod rename_aliases;
mod spring_split;

#[derive(Parser)]
#[command(name = "bar-lua-codemod")]
#[command(about = "AST-based Lua codemod tool for Beyond All Reason")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Convert bracket string access to dot notation (x["y"] -> x.y, ["y"] = -> y =)
    BracketToDot {
        /// Root directory to process
        #[arg(long, default_value = ".")]
        path: PathBuf,

        /// Directories to exclude (relative to path, may be repeated)
        #[arg(long)]
        exclude: Vec<String>,

        /// Report changes without writing files
        #[arg(long)]
        dry_run: bool,
    },

    /// Rename deprecated Spring method aliases to canonical names
    RenameAliases {
        /// Root directory to process
        #[arg(long, default_value = ".")]
        path: PathBuf,

        /// Directories to exclude (relative to path, may be repeated)
        #[arg(long)]
        exclude: Vec<String>,

        /// Report changes without writing files
        #[arg(long)]
        dry_run: bool,
    },

    /// Detach BAR modules from the Spring table (Spring.I18N -> I18N, etc.)
    DetachBarModules {
        /// Root directory to process
        #[arg(long, default_value = ".")]
        path: PathBuf,

        /// Directories to exclude (relative to path, may be repeated)
        #[arg(long)]
        exclude: Vec<String>,

        /// Report changes without writing files
        #[arg(long)]
        dry_run: bool,
    },

    /// Replace vendored gajop/i18n with kikito/i18n.lua and transform unit-name call sites
    I18nKikito {
        /// Root directory to process
        #[arg(long, default_value = ".")]
        path: PathBuf,

        /// Directories to exclude (relative to path, may be repeated)
        #[arg(long)]
        exclude: Vec<String>,

        /// Report changes without writing files
        #[arg(long)]
        dry_run: bool,
    },

    /// Replace Spring.X with SpringSynced.X or SpringShared.X based on API stubs
    SpringSplit {
        /// Root directory to process
        #[arg(long, default_value = ".")]
        path: PathBuf,

        /// Path to recoil-lua-library/library (contains generated stubs)
        #[arg(long)]
        library: PathBuf,

        /// Directories to exclude (relative to path, may be repeated)
        #[arg(long)]
        exclude: Vec<String>,

        /// Report changes without writing files
        #[arg(long)]
        dry_run: bool,
    },
}

fn collect_lua_files(root: &PathBuf, excludes: &[String]) -> Vec<PathBuf> {
    let pattern = format!("{}/**/*.lua", root.display());
    let mut files = Vec::new();
    for entry in glob::glob(&pattern).expect("invalid glob pattern") {
        if let Ok(path) = entry {
            let rel = path.strip_prefix(root).unwrap_or(&path);
            let excluded = excludes
                .iter()
                .any(|ex| rel.starts_with(ex));
            if !excluded {
                files.push(path);
            }
        }
    }
    files.sort();
    files
}

fn format_num(n: usize) -> String {
    let s = n.to_string();
    let bytes = s.as_bytes();
    let len = bytes.len();
    let mut result = String::new();
    for (i, &b) in bytes.iter().enumerate() {
        if i > 0 && (len - i) % 3 == 0 {
            result.push(',');
        }
        result.push(b as char);
    }
    result
}

fn run_bracket_to_dot(root: &PathBuf, excludes: &[String], dry_run: bool) {
    let files = collect_lua_files(root, excludes);
    let total_files = files.len();

    if total_files == 0 {
        eprintln!("No .lua files found under {}", root.display());
        process::exit(1);
    }

    let mut files_changed: usize = 0;
    let mut total_index: usize = 0;
    let mut total_field: usize = 0;
    let mut total_skipped: usize = 0;
    let mut errors: usize = 0;
    let mut per_file: Vec<(PathBuf, usize, usize)> = Vec::new();

    for file_path in &files {
        let code = match fs::read_to_string(file_path) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("  error reading {}: {}", file_path.display(), e);
                errors += 1;
                continue;
            }
        };

        let ast = match full_moon::parse(&code) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("  parse error in {}: {:?}", file_path.display(), e);
                errors += 1;
                continue;
            }
        };

        let mut visitor = bracket_to_dot::BracketToDot::new(&code);
        let new_ast = visitor.visit_ast(ast);

        if visitor.index_conversions > 0 || visitor.field_conversions > 0 {
            if !dry_run {
                if let Err(e) = fs::write(file_path, new_ast.to_string()) {
                    eprintln!("  error writing {}: {}", file_path.display(), e);
                    errors += 1;
                    continue;
                }
            }
            files_changed += 1;
            total_index += visitor.index_conversions;
            total_field += visitor.field_conversions;
            total_skipped += visitor.skipped_reserved;
            per_file.push((
                file_path.clone(),
                visitor.index_conversions,
                visitor.field_conversions,
            ));
        }
    }

    let total_conversions = total_index + total_field;

    if dry_run {
        println!("bar-lua-codemod bracket-to-dot (DRY RUN):");
    } else {
        println!("bar-lua-codemod bracket-to-dot results:");
    }
    println!("  Files scanned:  {:>30}", format_num(total_files));
    println!("  Files changed:  {:>30}", format_num(files_changed));
    println!(
        "  Index conversions (x[\"y\"] -> x.y): {:>8}",
        format_num(total_index)
    );
    println!(
        "  Field conversions ([\"y\"] = -> y =): {:>8}",
        format_num(total_field)
    );
    println!(
        "  Total conversions:                  {:>8}",
        format_num(total_conversions)
    );
    println!(
        "  Skipped (reserved words):           {:>8}",
        format_num(total_skipped)
    );
    println!(
        "  Errors (parse failures):            {:>8}",
        format_num(errors)
    );

    if !per_file.is_empty() {
        per_file.sort_by(|a, b| (b.1 + b.2).cmp(&(a.1 + a.2)));
        println!();
        println!("Top files by conversion count:");
        for (path, idx, fld) in per_file.iter().take(20) {
            let rel = path.strip_prefix(root).unwrap_or(path);
            println!("  {:<60} {:>5}", rel.display(), idx + fld);
        }
    }

    if errors > 0 {
        process::exit(1);
    }
}

const BAR_ALIASES: &[(&str, &str)] = &[
    ("GetMyTeamID", "GetLocalTeamID"),
    ("GetMyAllyTeamID", "GetLocalAllyTeamID"),
    ("GetMyPlayerID", "GetLocalPlayerID"),
];

fn run_rename_aliases(root: &PathBuf, excludes: &[String], dry_run: bool) {
    let files = collect_lua_files(root, excludes);
    let total_files = files.len();

    if total_files == 0 {
        eprintln!("No .lua files found under {}", root.display());
        process::exit(1);
    }

    let mut files_changed: usize = 0;
    let mut total_conversions: usize = 0;
    let mut errors: usize = 0;
    let mut per_file: Vec<(PathBuf, usize)> = Vec::new();

    for file_path in &files {
        let code = match fs::read_to_string(file_path) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("  error reading {}: {}", file_path.display(), e);
                errors += 1;
                continue;
            }
        };

        let ast = match full_moon::parse(&code) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("  parse error in {}: {:?}", file_path.display(), e);
                errors += 1;
                continue;
            }
        };

        let mut visitor = rename_aliases::RenameAliases::new(BAR_ALIASES);
        let new_ast = visitor.visit_ast(ast);

        if visitor.conversions > 0 {
            if !dry_run {
                if let Err(e) = fs::write(file_path, new_ast.to_string()) {
                    eprintln!("  error writing {}: {}", file_path.display(), e);
                    errors += 1;
                    continue;
                }
            }
            files_changed += 1;
            total_conversions += visitor.conversions;
            per_file.push((file_path.clone(), visitor.conversions));
        }
    }

    if dry_run {
        println!("bar-lua-codemod rename-aliases (DRY RUN):");
    } else {
        println!("bar-lua-codemod rename-aliases results:");
    }
    println!("  Files scanned:     {:>7}", format_num(total_files));
    println!("  Files changed:     {:>7}", format_num(files_changed));
    println!("  Conversions:       {:>7}", format_num(total_conversions));
    println!("  Errors:            {:>7}", format_num(errors));

    if !per_file.is_empty() {
        per_file.sort_by(|a, b| b.1.cmp(&a.1));
        println!();
        println!("Top files by conversion count:");
        for (path, count) in per_file.iter().take(20) {
            let rel = path.strip_prefix(root).unwrap_or(path);
            println!("  {:<60} {:>5}", rel.display(), count);
        }
    }

    if errors > 0 {
        process::exit(1);
    }
}

const BAR_MODULES: &[&str] = &["I18N", "Utilities", "Debug", "Lava", "GetModOptionsCopy"];

fn run_detach_bar_modules(root: &PathBuf, excludes: &[String], dry_run: bool) {
    let files = collect_lua_files(root, excludes);
    let total_files = files.len();

    if total_files == 0 {
        eprintln!("No .lua files found under {}", root.display());
        process::exit(1);
    }

    let mut files_changed: usize = 0;
    let mut total_conversions: usize = 0;
    let mut errors: usize = 0;
    let mut per_file: Vec<(PathBuf, usize)> = Vec::new();

    for file_path in &files {
        let code = match fs::read_to_string(file_path) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("  error reading {}: {}", file_path.display(), e);
                errors += 1;
                continue;
            }
        };

        let ast = match full_moon::parse(&code) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("  parse error in {}: {:?}", file_path.display(), e);
                errors += 1;
                continue;
            }
        };

        let mut visitor = detach_bar_modules::DetachBarModules::new(BAR_MODULES);
        let new_ast = visitor.visit_ast(ast);

        if visitor.conversions > 0 {
            if !dry_run {
                if let Err(e) = fs::write(file_path, new_ast.to_string()) {
                    eprintln!("  error writing {}: {}", file_path.display(), e);
                    errors += 1;
                    continue;
                }
            }
            files_changed += 1;
            total_conversions += visitor.conversions;
            per_file.push((file_path.clone(), visitor.conversions));
        }
    }

    if dry_run {
        println!("bar-lua-codemod detach-bar-modules (DRY RUN):");
    } else {
        println!("bar-lua-codemod detach-bar-modules results:");
    }
    println!("  Modules detached:  {:>7}", BAR_MODULES.join(", "));
    println!("  Files scanned:     {:>7}", format_num(total_files));
    println!("  Files changed:     {:>7}", format_num(files_changed));
    println!("  Conversions:       {:>7}", format_num(total_conversions));
    println!("  Errors:            {:>7}", format_num(errors));

    if !per_file.is_empty() {
        per_file.sort_by(|a, b| b.1.cmp(&a.1));
        println!();
        println!("Top files by conversion count:");
        for (path, count) in per_file.iter().take(20) {
            let rel = path.strip_prefix(root).unwrap_or(path);
            println!("  {:<60} {:>5}", rel.display(), count);
        }
    }

    if errors > 0 {
        process::exit(1);
    }
}

fn run_i18n_kikito(root: &PathBuf, excludes: &[String], dry_run: bool) {
    // Part A: Rewrite the wrapper
    let wrapper_path = root.join("modules/i18n/i18n.lua");
    let wrapper_content = match fs::read_to_string(&wrapper_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("  error reading wrapper {}: {}", wrapper_path.display(), e);
            process::exit(1);
        }
    };

    match i18n_kikito::rewrite_wrapper(&wrapper_content) {
        Ok(new_content) => {
            if !dry_run {
                if let Err(e) = fs::write(&wrapper_path, &new_content) {
                    eprintln!("  error writing wrapper: {}", e);
                    process::exit(1);
                }
            }
            println!("  Wrapper rewritten: {}", wrapper_path.display());
        }
        Err(e) => {
            eprintln!("  error rewriting wrapper: {}", e);
            process::exit(1);
        }
    }

    // Part B: Transform call sites
    let files = collect_lua_files(root, excludes);
    let total_files = files.len();

    if total_files == 0 {
        eprintln!("No .lua files found under {}", root.display());
        process::exit(1);
    }

    let mut files_changed: usize = 0;
    let mut total_conversions: usize = 0;
    let mut errors: usize = 0;
    let mut per_file: Vec<(PathBuf, usize)> = Vec::new();

    for file_path in &files {
        let code = match fs::read_to_string(file_path) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("  error reading {}: {}", file_path.display(), e);
                errors += 1;
                continue;
            }
        };

        let ast = match full_moon::parse(&code) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("  parse error in {}: {:?}", file_path.display(), e);
                errors += 1;
                continue;
            }
        };

        let mut visitor = i18n_kikito::I18nCallSites::new();
        let new_ast = visitor.visit_ast(ast);

        if visitor.conversions > 0 {
            if !dry_run {
                if let Err(e) = fs::write(file_path, new_ast.to_string()) {
                    eprintln!("  error writing {}: {}", file_path.display(), e);
                    errors += 1;
                    continue;
                }
            }
            files_changed += 1;
            total_conversions += visitor.conversions;
            per_file.push((file_path.clone(), visitor.conversions));
        }
    }

    if dry_run {
        println!("bar-lua-codemod i18n-kikito (DRY RUN):");
    } else {
        println!("bar-lua-codemod i18n-kikito results:");
    }
    println!("  Files scanned:        {:>7}", format_num(total_files));
    println!("  Files changed:        {:>7}", format_num(files_changed));
    println!("  Call-site conversions: {:>7}", format_num(total_conversions));
    println!("  Errors:               {:>7}", format_num(errors));

    if !per_file.is_empty() {
        per_file.sort_by(|a, b| b.1.cmp(&a.1));
        println!();
        println!("Top files by conversion count:");
        for (path, count) in per_file.iter().take(20) {
            let rel = path.strip_prefix(root).unwrap_or(path);
            println!("  {:<60} {:>5}", rel.display(), count);
        }
    }

    if errors > 0 {
        process::exit(1);
    }
}

fn run_spring_split(root: &PathBuf, library: &PathBuf, excludes: &[String], dry_run: bool) {
    let mapping = spring_split::build_mapping(library);
    let mapping_size = mapping.len();
    eprintln!(
        "  Loaded {} method mappings from {}",
        mapping_size,
        library.display()
    );

    if mapping_size == 0 {
        eprintln!("No method mappings found -- check --library path");
        process::exit(1);
    }

    let files = collect_lua_files(root, excludes);
    let total_files = files.len();

    if total_files == 0 {
        eprintln!("No .lua files found under {}", root.display());
        process::exit(1);
    }

    let mut files_changed: usize = 0;
    let mut total_conversions: usize = 0;
    let mut total_unmapped: usize = 0;
    let mut errors: usize = 0;
    let mut per_file: Vec<(PathBuf, usize)> = Vec::new();
    let mut all_unmapped: std::collections::HashMap<String, usize> = std::collections::HashMap::new();

    for file_path in &files {
        let code = match fs::read_to_string(file_path) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("  error reading {}: {}", file_path.display(), e);
                errors += 1;
                continue;
            }
        };

        let ast = match full_moon::parse(&code) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("  parse error in {}: {:?}", file_path.display(), e);
                errors += 1;
                continue;
            }
        };

        let mut visitor = spring_split::SpringSplit::new(mapping.clone());
        let new_ast = visitor.visit_ast(ast);

        total_unmapped += visitor.unmapped;
        for (name, count) in &visitor.unmapped_names {
            *all_unmapped.entry(name.clone()).or_insert(0) += count;
        }

        if visitor.conversions > 0 {
            if !dry_run {
                if let Err(e) = fs::write(file_path, new_ast.to_string()) {
                    eprintln!("  error writing {}: {}", file_path.display(), e);
                    errors += 1;
                    continue;
                }
            }
            files_changed += 1;
            total_conversions += visitor.conversions;
            per_file.push((file_path.clone(), visitor.conversions));
        }
    }

    if dry_run {
        println!("bar-lua-codemod spring-split (DRY RUN):");
    } else {
        println!("bar-lua-codemod spring-split results:");
    }
    println!("  Method mappings loaded:             {:>8}", format_num(mapping_size));
    println!("  Files scanned:                      {:>8}", format_num(total_files));
    println!("  Files changed:                      {:>8}", format_num(files_changed));
    println!("  Spring.X -> Specific.X conversions: {:>8}", format_num(total_conversions));
    println!("  Unmapped Spring.X references:       {:>8}", format_num(total_unmapped));
    println!("  Errors (parse failures):            {:>8}", format_num(errors));

    if !per_file.is_empty() {
        per_file.sort_by(|a, b| b.1.cmp(&a.1));
        println!();
        println!("Top files by conversion count:");
        for (path, count) in per_file.iter().take(20) {
            let rel = path.strip_prefix(root).unwrap_or(path);
            println!("  {:<60} {:>5}", rel.display(), count);
        }
    }

    if !all_unmapped.is_empty() {
        let mut unmapped_sorted: Vec<_> = all_unmapped.into_iter().collect();
        unmapped_sorted.sort_by(|a, b| b.1.cmp(&a.1));
        println!();
        println!("Unmapped Spring.X methods ({} unique):", unmapped_sorted.len());
        for (name, count) in &unmapped_sorted {
            println!("  {:<50} {:>5}", name, count);
        }
    }

    if errors > 0 {
        process::exit(1);
    }
}

fn main() {
    let cli = Cli::parse();
    match cli.command {
        Commands::BracketToDot {
            path,
            exclude,
            dry_run,
        } => run_bracket_to_dot(&path, &exclude, dry_run),
        Commands::RenameAliases {
            path,
            exclude,
            dry_run,
        } => run_rename_aliases(&path, &exclude, dry_run),
        Commands::DetachBarModules {
            path,
            exclude,
            dry_run,
        } => run_detach_bar_modules(&path, &exclude, dry_run),
        Commands::I18nKikito {
            path,
            exclude,
            dry_run,
        } => run_i18n_kikito(&path, &exclude, dry_run),
        Commands::SpringSplit {
            path,
            library,
            exclude,
            dry_run,
        } => run_spring_split(&path, &library, &exclude, dry_run),
    }
}
