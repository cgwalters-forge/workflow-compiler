//! Evaluating nickel in-process with `nickel-lang-core`.

use std::path::Path;

use anyhow::{Context, Result, anyhow};
use nickel_lang_core::error::report::{ColorOpt, report_as_str};
use nickel_lang_core::eval::cache::CacheImpl;
use nickel_lang_core::program::{Program, ProgramBuilder};
use nickel_lang_core::serialize::{self, ExportFormat};

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

/// Evaluates the nickel file at `root/source` and exports it as YAML, as
/// `nickel export --format yaml` does.
pub fn export_yaml(root: &Path, source: &str) -> Result<String> {
    let path = root.join(source);
    let program = ProgramBuilder::new()
        .add_path(&path)
        .build()
        .with_context(|| format!("loading {}", path.display()))?;
    export(program, source, ExportFormat::Yaml)
}
