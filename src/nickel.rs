//! Evaluating nickel in-process with `nickel-lang-core`.
//!
//! nickel reads an `import` from the filesystem by itself, against any
//! path (`/etc/passwd`, `../x`, a symlink out of the tree), and has no
//! hook to read through a directory fd instead. So wfc never lets it: it
//! reads the source and everything it imports, transitively, through the
//! [`Repo`], which refuses paths outside the repository's readable part,
//! and gives nickel those texts as in-memory sources under
//! [`VIRTUAL_ROOT`]. An import that resolves to one of them is found in
//! memory; the imports are known before evaluation starts (nickel's
//! `import` takes only a literal), and one that isn't there fails before
//! anything is evaluated. After evaluation, wfc checks that nickel loaded
//! nothing else.

use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use nickel_lang_core::ast::{Ast, AstAlloc, Import, InputFormat, Node};
use nickel_lang_core::cache::{CacheHub, SourcePath};
use nickel_lang_core::error::report::{ColorOpt, report_as_str};
use nickel_lang_core::error::{Error, IntoDiagnostics, NullReporter};
use nickel_lang_core::eval::VirtualMachine;
use nickel_lang_core::eval::cache::CacheImpl;
use nickel_lang_core::eval::value::NickelValue;
use nickel_lang_core::files::FileId;
use nickel_lang_core::serialize::{self, ExportFormat};
use nickel_lang_core::traverse::{TraverseAlloc, TraverseControl};

use crate::repo::{self, Repo};

type VmContext = nickel_lang_core::eval::VmContext<CacheHub, CacheImpl>;

/// Where the repository's files appear to nickel: an absolute path (nickel
/// normalizes imports to absolute ones) that names no real directory, so
/// that nothing it could resolve by itself is a file of the repository.
/// Reports show paths relative to the root instead.
const VIRTUAL_ROOT: &str = "/%wfc%";

/// The stack evaluation runs on: nickel's evaluation recurses deeply, and
/// a spawned thread's default is 2 MiB.
const STACK_SIZE: usize = 256 << 20;

/// `rel`, as nickel sees it.
fn virtual_path(rel: &str) -> PathBuf {
    Path::new(VIRTUAL_ROOT).join(rel)
}

/// The file `import` names, relative to the root, from the file `from`;
/// an error if it isn't a plain path in the repository.
fn resolve_import(from: &str, import: &OsStr) -> Result<String> {
    let text = import
        .to_str()
        .with_context(|| format!("{from} imports a path that isn't UTF-8"))?;
    let path = Path::new(text);
    if path.is_absolute() {
        bail!(
            "{from} imports {text}, an absolute path; imports must be relative to the importing file"
        );
    }
    // Lexically, like nickel: `..` removes the previous component.
    let mut parts: Vec<&OsStr> = Path::new(from)
        .components()
        .map(|c| c.as_os_str())
        .collect();
    parts.pop();
    for c in path.components() {
        match c {
            Component::Normal(name) => parts.push(name),
            Component::CurDir => {}
            Component::ParentDir => {
                if parts.pop().is_none() {
                    bail!("{from} imports {text}, outside the repository");
                }
            }
            Component::RootDir | Component::Prefix(_) => {
                bail!("{from} imports {text}, which is not a relative path")
            }
        }
    }
    let rel = parts.iter().collect::<PathBuf>();
    let rel = rel
        .to_str()
        .with_context(|| format!("{from} imports a path that isn't UTF-8"))?
        .to_owned();
    if !repo::is_readable(&rel) {
        bail!(
            "{from} imports {rel}, outside what a compile reads ({})",
            repo::READABLE.join(", ")
        );
    }
    Ok(rel)
}

/// Replaces [`VIRTUAL_ROOT`] in a report with the root's relative paths.
fn unvirtualize(report: &str) -> String {
    report.replace(&format!("{VIRTUAL_ROOT}/"), "")
}

/// nickel's report of `error`.
fn report(cache: &CacheHub, error: impl IntoDiagnostics) -> String {
    unvirtualize(&report_as_str(
        &mut cache.sources.files().clone(),
        error,
        ColorOpt::Never,
    ))
}

/// `source` and every file it imports, transitively, read through `repo`
/// and loaded into a fresh cache. Returns the cache, the id of `source`
/// and the ids of every file loaded.
fn load(repo: &Repo, source: &str) -> Result<(CacheHub, FileId, HashSet<FileId>)> {
    let mut cache = CacheHub::new();
    let alloc = AstAlloc::new();
    let mut loaded: HashMap<(String, InputFormat), FileId> = HashMap::new();
    // What to load, and the file that imports it.
    let mut queue = vec![(source.to_owned(), InputFormat::Nickel, None)];
    let mut main = None;
    while let Some((rel, format, importer)) = queue.pop() {
        if loaded.contains_key(&(rel.clone(), format)) {
            continue;
        }
        let what = match &importer {
            Some(importer) => format!("{rel}, imported by {importer},"),
            None => rel.clone(),
        };
        let text = repo
            .read(&rel)
            .with_context(|| format!("{source} does not compile: reading {what}"))?
            .ok_or_else(|| anyhow!("{source} does not compile: {what} does not exist"))?;
        let id = cache
            .sources
            .add_string(SourcePath::Path(virtual_path(&rel), format), text);
        main.get_or_insert(id);
        loaded.insert((rel.clone(), format), id);
        if format != InputFormat::Nickel {
            continue;
        }
        let ast = cache.sources.parse_nickel(&alloc, id).map_err(|e| {
            anyhow!(
                "{source} does not compile:\n{}",
                report(&cache, Error::ParseErrors(e))
            )
        })?;
        let mut imports = Vec::new();
        ast.traverse_ref(
            &mut |node: &Ast<'_>, _: &()| {
                if let Node::Import(import) = &node.node {
                    imports.push(import.clone());
                }
                TraverseControl::<(), ()>::Continue
            },
            &(),
        );
        for import in imports {
            match import {
                Import::Path { path, format } => {
                    let target = resolve_import(&rel, path)
                        .with_context(|| format!("{source} does not compile"))?;
                    queue.push((target, format, Some(rel.clone())));
                }
                Import::Package { .. } => {
                    bail!(
                        "{source} does not compile: {rel} imports a package, which wfc doesn't support"
                    )
                }
            }
        }
    }
    let main = main.expect("the source itself is always loaded");
    Ok((cache, main, loaded.into_values().collect()))
}

/// Fails if nickel loaded a file that `load` didn't give it.
fn check_loaded(vm: &VmContext, ours: &HashSet<FileId>, source: &str) -> Result<()> {
    let sources = &vm.import_resolver.sources;
    for (id, path) in &sources.file_paths {
        if matches!(path, SourcePath::Path(..)) && !ours.contains(id) {
            bail!("{source}: nickel loaded {path:?} by itself; refusing its output");
        }
    }
    Ok(())
}

/// Evaluates `source` and every file it imports, read through `repo`, and
/// exports it in `format`, as `nickel export` does. Errors carry nickel's
/// own report.
fn export(repo: &Repo, source: &str, format: ExportFormat) -> Result<String> {
    let (cache, main, ours) = load(repo, source)?;
    let mut vm = VmContext::new(cache, std::io::sink(), NullReporter {});
    let value: Result<NickelValue, Error> = vm.prepare_eval(main).and_then(|prepared| {
        VirtualMachine::new(&mut vm)
            .eval_full_for_export_closure(prepared.into())
            .map_err(Error::from)
    });
    check_loaded(&vm, &ours, source)?;
    let value = value.map_err(|error| {
        anyhow!(
            "{source} does not compile:\n{}",
            report(&vm.import_resolver, error)
        )
    })?;
    serialize::validate(format, &value)
        .and_then(|()| serialize::to_string(format, &value))
        .map_err(|error| {
            let error = error.with_pos_table(vm.pos_table.clone());
            anyhow!(
                "{source} can't be exported as {format}:\n{}",
                report(&vm.import_resolver, error)
            )
        })
}

/// Evaluates the nickel file `source` (relative to the root) and exports
/// it as YAML, as `nickel export --format yaml` does.
pub fn export_yaml(repo: &Repo, source: &str) -> Result<String> {
    std::thread::scope(|scope| {
        std::thread::Builder::new()
            .name("nickel".into())
            .stack_size(STACK_SIZE)
            .spawn_scoped(scope, || export(repo, source, ExportFormat::Yaml))
            .context("starting the evaluation thread")?
            .join()
            .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
    })
}
