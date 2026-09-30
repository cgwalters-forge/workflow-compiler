//! Evaluating nickel in-process with `nickel-lang-core`.

use std::io::Cursor;
use std::path::Path;

use anyhow::{Context, Result, anyhow, bail};
use nickel_lang_core::ast::record::FieldPathElem;
use nickel_lang_core::ast::{Ast, AstAlloc, InputFormat, Node, StringChunk};
use nickel_lang_core::cache::{CacheHub, SourcePath};
use nickel_lang_core::error::report::{ColorOpt, report_as_str};
use nickel_lang_core::eval::cache::CacheImpl;
use nickel_lang_core::program::{Program, ProgramBuilder};
use nickel_lang_core::serialize::{self, ExportFormat};
use nickel_lang_core::traverse::{TraverseAlloc, TraverseControl};

use crate::repo::Repo;

/// The most lines a `run` script may have inline in a source; a longer
/// one goes in a file of its own.
pub const MAX_INLINE_SCRIPT_LINES: usize = 10;

/// A source, evaluated.
pub struct Export {
    /// Its YAML, as `nickel export --format yaml` writes it.
    pub yaml: String,
    /// The files in the repository it loaded, itself included, relative
    /// to the root and sorted.
    pub files: Vec<String>,
}

/// Evaluates `program` and exports it in `format`, as `nickel export`
/// does. Errors carry nickel's own report.
fn evaluate(program: &mut Program<CacheImpl>, name: &str, format: ExportFormat) -> Result<String> {
    let value = match program.eval_full_for_export() {
        Ok(value) => value,
        Err(error) => {
            let report = report_as_str(&mut program.files(), error, ColorOpt::Never);
            return Err(anyhow!("{name} does not compile:\n{report}"));
        }
    };
    serialize::validate(format, &value)
        .and_then(|()| serialize::to_string(format, &value))
        .map_err(|error| {
            let error = error.with_pos_table(program.pos_table().clone());
            let report = report_as_str(&mut program.files(), error, ColorOpt::Never);
            anyhow!("{name} can't be exported as {format}:\n{report}")
        })
}

/// The number of lines of `node` if it is a string literal, with or
/// without interpolations; `None` for anything else, an import included.
fn literal_lines(node: &Ast<'_>) -> Option<usize> {
    let newlines = match &node.node {
        Node::String(s) => s.trim_end_matches('\n').matches('\n').count(),
        Node::StringChunks(chunks) => chunks
            .iter()
            .map(|c| match c {
                StringChunk::Literal(s) => s.matches('\n').count(),
                StringChunk::Expr(..) => 0,
            })
            .sum(),
        _ => return None,
    };
    Some(newlines + 1)
}

/// The first `run` field in the nickel source `text` whose value is a
/// string literal of more than [`MAX_INLINE_SCRIPT_LINES`] lines: its
/// line number and its number of lines.
fn long_inline_script(rel: &str, text: &str) -> Result<Option<(usize, usize)>> {
    let mut cache = CacheHub::new();
    let id = cache.sources.add_string(
        SourcePath::Path(rel.into(), InputFormat::Nickel),
        text.to_owned(),
    );
    let alloc = AstAlloc::new();
    let ast = cache
        .sources
        .parse_nickel(&alloc, id)
        .map_err(|_| anyhow!("parsing {rel}"))?;
    let found = ast.traverse_ref(
        &mut |node: &Ast<'_>, _: &()| {
            if let Node::Record(record) = &node.node {
                for field in record.field_defs {
                    let is_run = matches!(field.path.last(),
                        Some(FieldPathElem::Ident(id)) if id.label() == "run");
                    let lines = field.value.as_ref().and_then(literal_lines);
                    if let (true, Some(lines)) = (is_run, lines)
                        && lines > MAX_INLINE_SCRIPT_LINES
                    {
                        let at = field.value.as_ref().and_then(|v| v.pos.into_opt());
                        let at = at.map_or(0, |span| span.start.to_usize());
                        let line = text[..at].matches('\n').count() + 1;
                        return TraverseControl::Return((line, lines));
                    }
                }
            }
            TraverseControl::Continue
        },
        &(),
    );
    Ok(found)
}

/// Evaluates the nickel file `source` (relative to the root), as `nickel
/// export --format yaml` does. A `run` field set to a literal longer than
/// [`MAX_INLINE_SCRIPT_LINES`] in any file it loads is refused: a script
/// that long goes in a file of its own, imported as text, where `wfc
/// check` lints it.
pub fn export(root: &Repo, source: &str) -> Result<Export> {
    let path = root.path(source);
    let mut program = ProgramBuilder::new()
        .add_path(&path)
        .build()
        .with_context(|| format!("loading {}", path.display()))?;
    let yaml = evaluate(&mut program, source, ExportFormat::Yaml)?;
    let mut files: Vec<String> = program
        .files()
        .filenames()
        .filter_map(|name| Path::new(name).strip_prefix(root.root()).ok()?.to_str())
        .map(str::to_owned)
        .collect();
    files.sort();
    files.dedup();
    for rel in files.iter().filter(|f| f.ends_with(".ncl")) {
        let text = root
            .read(rel)?
            .with_context(|| format!("{rel} disappeared"))?;
        if let Some((line, lines)) = long_inline_script(rel, &text)? {
            bail!(
                "{source} does not compile: {rel}:{line}: an inline `run` script of {lines} lines; \
                 scripts of more than {MAX_INLINE_SCRIPT_LINES} lines go in a file of their own, \
                 imported as text (`run = import \"scripts/x.sh\" as 'Text`), where `wfc check` lints them"
            );
        }
    }
    Ok(Export { yaml, files })
}

/// Evaluates the nickel file `source` (relative to the root) and exports
/// it as YAML, as `nickel export --format yaml` does.
pub fn export_yaml(root: &Repo, source: &str) -> Result<String> {
    Ok(export(root, source)?.yaml)
}

/// Parses `text` as YAML with nickel's parser, as data: YAML has no
/// imports. `name` is for error messages.
pub fn yaml_to_json(name: &str, text: &str) -> Result<serde_json::Value> {
    let mut program = ProgramBuilder::new()
        .add_source_with_format(Cursor::new(text.to_owned()), name, InputFormat::Yaml)
        .build()
        .with_context(|| format!("loading {name}"))?;
    let json = evaluate(&mut program, name, ExportFormat::Json)?;
    serde_json::from_str(&json).with_context(|| format!("reading {name} back as JSON"))
}
