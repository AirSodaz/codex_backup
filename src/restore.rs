use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context, Result};

use crate::staging::{copy_path, Manifest};

#[derive(Debug, Clone)]
pub struct ApplyRestoreOptions {
    pub restored_staging_dir: PathBuf,
    pub codex_dir: PathBuf,
    pub rollback_root: PathBuf,
    pub check_processes: bool,
    pub timestamp: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApplyRestoreResult {
    pub codex_dir: PathBuf,
    pub rollback_dir: PathBuf,
}

pub fn find_restored_staging(restore_root: &Path) -> Result<PathBuf> {
    let mut manifests = Vec::new();
    collect_manifests(restore_root, &mut manifests)?;
    manifests.sort_by_key(|path| {
        fs::metadata(path)
            .and_then(|metadata| metadata.modified())
            .ok()
    });
    manifests.reverse();

    for manifest_path in manifests {
        let Ok(contents) = fs::read_to_string(&manifest_path) else {
            continue;
        };
        let Ok(manifest) = serde_json::from_str::<Manifest>(&contents) else {
            continue;
        };
        if manifest.backup_name == "codex-history" && manifest.schema_version == 1 {
            return manifest_path
                .parent()
                .map(Path::to_path_buf)
                .context("manifest path has no parent");
        }
    }

    bail!(
        "No codex-history manifest found under: {}",
        restore_root.display()
    )
}

pub fn apply_restore(options: ApplyRestoreOptions) -> Result<ApplyRestoreResult> {
    let manifest_path = options.restored_staging_dir.join("manifest.json");
    let manifest: Manifest = serde_json::from_str(
        &fs::read_to_string(&manifest_path)
            .with_context(|| format!("failed to read manifest {}", manifest_path.display()))?,
    )
    .with_context(|| format!("failed to parse manifest {}", manifest_path.display()))?;

    if manifest.backup_name != "codex-history" || manifest.schema_version != 1 {
        bail!("Unsupported restore manifest: {}", manifest_path.display());
    }

    if options.check_processes {
        ensure_codex_process_stopped()?;
    }

    fs::create_dir_all(&options.codex_dir)
        .with_context(|| format!("failed to create {}", options.codex_dir.display()))?;
    let rollback_dir = options
        .rollback_root
        .join(format!("codex-before-restore-{}", options.timestamp));
    fs::create_dir_all(&rollback_dir)
        .with_context(|| format!("failed to create {}", rollback_dir.display()))?;

    for relative_path in &manifest.included_paths {
        let source = options.restored_staging_dir.join(relative_path);
        if !source.exists() {
            continue;
        }
        let destination = options.codex_dir.join(relative_path);
        move_existing_to_rollback(&destination, &options.codex_dir, &rollback_dir)?;
        copy_path(&source, &destination)?;
    }

    for sqlite_backup in &manifest.sqlite_backups {
        let source = options
            .restored_staging_dir
            .join(Path::new(&sqlite_backup.backup_file));
        if !source.exists() {
            bail!(
                "SQLite backup missing from restored snapshot: {}",
                sqlite_backup.backup_file
            );
        }

        let destination = options.codex_dir.join(&sqlite_backup.source_file);
        move_existing_to_rollback(&destination, &options.codex_dir, &rollback_dir)?;
        move_existing_to_rollback(
            &PathBuf::from(format!("{}-wal", destination.display())),
            &options.codex_dir,
            &rollback_dir,
        )?;
        move_existing_to_rollback(
            &PathBuf::from(format!("{}-shm", destination.display())),
            &options.codex_dir,
            &rollback_dir,
        )?;
        copy_path(&source, &destination)?;
    }

    Ok(ApplyRestoreResult {
        codex_dir: options.codex_dir,
        rollback_dir,
    })
}

fn collect_manifests(root: &Path, manifests: &mut Vec<PathBuf>) -> Result<()> {
    if !root.exists() {
        return Ok(());
    }

    for entry in fs::read_dir(root).with_context(|| format!("failed to read {}", root.display()))? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            collect_manifests(&path, manifests)?;
        } else if path.file_name().is_some_and(|name| name == "manifest.json") {
            manifests.push(path);
        }
    }

    Ok(())
}

fn move_existing_to_rollback(path: &Path, codex_dir: &Path, rollback_dir: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }

    let relative = path.strip_prefix(codex_dir).with_context(|| {
        format!(
            "path {} is not inside Codex directory {}",
            path.display(),
            codex_dir.display()
        )
    })?;
    let destination = rollback_dir.join(relative);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    fs::rename(path, &destination).with_context(|| {
        format!(
            "failed to move {} to rollback {}",
            path.display(),
            destination.display()
        )
    })?;
    Ok(())
}

fn ensure_codex_process_stopped() -> Result<()> {
    let running = if cfg!(target_os = "windows") {
        Command::new("tasklist")
            .output()
            .ok()
            .and_then(|output| String::from_utf8(output.stdout).ok())
            .is_some_and(|output| output.lines().any(process_line_mentions_codex))
    } else {
        Command::new("pgrep")
            .args(["-x", "Codex"])
            .status()
            .is_ok_and(|status| status.success())
            || Command::new("pgrep")
                .args(["-x", "codex"])
                .status()
                .is_ok_and(|status| status.success())
    };

    if running {
        bail!("Codex appears to be running. Close Codex before applying a restore.");
    }

    Ok(())
}

fn process_line_mentions_codex(line: &str) -> bool {
    let Some(name) = line.split_whitespace().next() else {
        return false;
    };
    name.eq_ignore_ascii_case("codex.exe") || name.eq_ignore_ascii_case("codex")
}
