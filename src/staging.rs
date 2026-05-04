use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use chrono::Utc;
use rusqlite::{backup::Backup, Connection};
use serde::{Deserialize, Serialize};

use crate::paths::{excluded_relative_paths, managed_relative_paths};

#[derive(Debug, Clone)]
pub struct StagingOptions {
    pub codex_dir: PathBuf,
    pub work_root: PathBuf,
    pub timestamp: String,
}

#[derive(Debug, Clone)]
pub struct StagingResult {
    pub staging_dir: PathBuf,
    pub manifest_path: PathBuf,
    pub included_paths: Vec<String>,
    pub sqlite_backups: Vec<SqliteBackup>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u8,
    pub backup_name: String,
    pub created_at: String,
    pub host: String,
    pub user: String,
    pub codex_dir: String,
    pub included_paths: Vec<String>,
    pub excluded_paths: Vec<String>,
    pub sqlite_backups: Vec<SqliteBackup>,
    pub restore_notes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SqliteBackup {
    pub source_file: String,
    pub backup_file: String,
    pub source_last_write_time: String,
    pub size_bytes: u64,
}

impl Manifest {
    pub fn for_test(included_paths: Vec<String>, sqlite_pairs: Vec<(String, String)>) -> Self {
        Self {
            schema_version: 1,
            backup_name: "codex-history".to_string(),
            created_at: "2026-05-04T00:00:00Z".to_string(),
            host: "test-host".to_string(),
            user: "test-user".to_string(),
            codex_dir: "/tmp/.codex".to_string(),
            included_paths,
            excluded_paths: excluded_relative_paths()
                .into_iter()
                .map(str::to_string)
                .collect(),
            sqlite_backups: sqlite_pairs
                .into_iter()
                .map(|(source_file, backup_file)| SqliteBackup {
                    source_file,
                    backup_file,
                    source_last_write_time: "2026-05-04T00:00:00Z".to_string(),
                    size_bytes: 0,
                })
                .collect(),
            restore_notes: restore_notes(),
        }
    }
}

pub fn create_staging(options: StagingOptions) -> Result<StagingResult> {
    if !options.codex_dir.exists() {
        bail!("Codex directory not found: {}", options.codex_dir.display());
    }

    fs::create_dir_all(&options.work_root).with_context(|| {
        format!(
            "failed to create staging work root {}",
            options.work_root.display()
        )
    })?;

    let staging_dir = options
        .work_root
        .join(format!("codex-backup-{}", options.timestamp));
    if staging_dir.exists() {
        bail!(
            "Staging directory already exists: {}",
            staging_dir.display()
        );
    }
    fs::create_dir_all(&staging_dir)
        .with_context(|| format!("failed to create staging dir {}", staging_dir.display()))?;

    let mut included_paths = Vec::new();
    for relative_path in managed_relative_paths() {
        let source = options.codex_dir.join(relative_path);
        if !source.exists() {
            continue;
        }
        let destination = staging_dir.join(relative_path);
        copy_path(&source, &destination)?;
        included_paths.push(relative_path.to_string());
    }

    let sqlite_backups = backup_root_sqlite_files(&options.codex_dir, &staging_dir)?;
    let manifest = Manifest {
        schema_version: 1,
        backup_name: "codex-history".to_string(),
        created_at: Utc::now().to_rfc3339(),
        host: host_name(),
        user: user_name(),
        codex_dir: options
            .codex_dir
            .canonicalize()
            .unwrap_or_else(|_| options.codex_dir.clone())
            .display()
            .to_string(),
        included_paths: included_paths.clone(),
        excluded_paths: excluded_relative_paths()
            .into_iter()
            .map(str::to_string)
            .collect(),
        sqlite_backups: sqlite_backups.clone(),
        restore_notes: restore_notes(),
    };

    let manifest_path = staging_dir.join("manifest.json");
    fs::write(&manifest_path, serde_json::to_string_pretty(&manifest)?)
        .with_context(|| format!("failed to write manifest {}", manifest_path.display()))?;

    Ok(StagingResult {
        staging_dir,
        manifest_path,
        included_paths,
        sqlite_backups,
    })
}

pub fn copy_path(source: &Path, destination: &Path) -> Result<()> {
    if source.is_dir() {
        fs::create_dir_all(destination)
            .with_context(|| format!("failed to create {}", destination.display()))?;
        for entry in fs::read_dir(source)
            .with_context(|| format!("failed to read directory {}", source.display()))?
        {
            let entry = entry?;
            copy_path(&entry.path(), &destination.join(entry.file_name()))?;
        }
    } else {
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        fs::copy(source, destination).with_context(|| {
            format!(
                "failed to copy {} to {}",
                source.display(),
                destination.display()
            )
        })?;
    }

    Ok(())
}

fn backup_root_sqlite_files(codex_dir: &Path, staging_dir: &Path) -> Result<Vec<SqliteBackup>> {
    let sqlite_dir = staging_dir.join("sqlite");
    let mut backups = Vec::new();

    for entry in fs::read_dir(codex_dir)
        .with_context(|| format!("failed to read Codex directory {}", codex_dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let file_name = entry.file_name().to_string_lossy().to_string();
        let is_managed_sqlite = file_name.ends_with(".sqlite")
            && (file_name.starts_with("logs_") || file_name.starts_with("state_"));
        if !is_managed_sqlite {
            continue;
        }

        fs::create_dir_all(&sqlite_dir)
            .with_context(|| format!("failed to create {}", sqlite_dir.display()))?;
        let destination = sqlite_dir.join(&file_name);
        sqlite_backup(&path, &destination)?;

        let metadata = fs::metadata(&destination)?;
        let source_modified = fs::metadata(&path)?
            .modified()
            .ok()
            .map(chrono::DateTime::<Utc>::from)
            .map(|time| time.to_rfc3339())
            .unwrap_or_else(|| Utc::now().to_rfc3339());

        backups.push(SqliteBackup {
            source_file: file_name.clone(),
            backup_file: format!("sqlite/{file_name}"),
            source_last_write_time: source_modified,
            size_bytes: metadata.len(),
        });
    }

    backups.sort_by(|left, right| left.source_file.cmp(&right.source_file));
    Ok(backups)
}

fn sqlite_backup(source: &Path, destination: &Path) -> Result<()> {
    if destination.exists() {
        fs::remove_file(destination)
            .with_context(|| format!("failed to remove {}", destination.display()))?;
    }

    let source_connection = Connection::open(source)
        .with_context(|| format!("failed to open SQLite source {}", source.display()))?;
    let mut destination_connection = Connection::open(destination)
        .with_context(|| format!("failed to open SQLite backup {}", destination.display()))?;
    let backup = Backup::new(&source_connection, &mut destination_connection)?;
    backup.run_to_completion(5, Duration::from_millis(250), None)?;
    Ok(())
}

fn restore_notes() -> Vec<String> {
    vec![
        "Close Codex before applying restored files.".to_string(),
        "auth.json and .sandbox-secrets are intentionally excluded.".to_string(),
        "SQLite files are restored from online .backup snapshots; stale WAL/SHM files are moved aside during apply.".to_string(),
    ]
}

fn host_name() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "unknown-host".to_string())
}

fn user_name() -> String {
    std::env::var("USERNAME")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_else(|_| "unknown-user".to_string())
}
