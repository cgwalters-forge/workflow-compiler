//! Evaluating nickel in-process with `nickel-lang-core`.

use std::io::Cursor;

use anyhow::{Context, Result, anyhow};
use nickel_lang_core::ast::InputFormat;
use nickel_lang_core::error::report::{ColorOpt, report_as_str};
use nickel_lang_core::eval::cache::CacheImpl;
use nickel_lang_core::program::{Program, ProgramBuilder};
use nickel_lang_core::serialize::{self, ExportFormat};

use crate::repo::Repo;

/// Evaluates `program` and exports it in `format`, as `nickel export`
/// does. Errors carry nickel's own report.
fn export(mut program: Program<CacheImpl>, name: &str, format: ExportFormat) -> Result<String> {
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

/// Evaluates the nickel file `source` (relative to the root) and exports
/// it as YAML, as `nickel export --format yaml` does.
pub fn export_yaml(root: &Repo, source: &str) -> Result<String> {
    let path = root.path(source);
    let program = ProgramBuilder::new()
        .add_path(&path)
        .build()
        .with_context(|| format!("loading {}", path.display()))?;
    export(program, source, ExportFormat::Yaml)
}

/// Parses `text` as YAML with nickel's parser, as data: YAML has no
/// imports. `name` is for error messages.
pub fn yaml_to_json(name: &str, text: &str) -> Result<serde_json::Value> {
    let program = ProgramBuilder::new()
        .add_source_with_format(Cursor::new(text.to_owned()), name, InputFormat::Yaml)
        .build()
        .with_context(|| format!("loading {name}"))?;
    let json = export(program, name, ExportFormat::Json)?;
    serde_json::from_str(&json).with_context(|| format!("reading {name} back as JSON"))
}
