use std::env;
use std::path::PathBuf;

use anyhow::{Context, Result};
use directories::{BaseDirs, ProjectDirs};

const MANAGED_DIRECTORIES: &[&str] = &["sessions", "archived_sessions", "memories"];
const MANAGED_FILES: &[&str] = &["session_index.jsonl", "history.jsonl"];
const EXCLUDED_PATHS: &[&str] = &[
    "auth.json",
    ".sandbox-secrets",
    "cache",
    "tmp",
    ".tmp",
    ".sandbox",
    ".sandbox-bin",
    "plugins/cache",
    "vendor_imports",
    "worktrees",
];

pub fn managed_relative_paths() -> Vec<&'static str> {
    MANAGED_DIRECTORIES
        .iter()
        .chain(MANAGED_FILES.iter())
        .copied()
        .collect()
}

pub fn excluded_relative_paths() -> Vec<&'static str> {
    EXCLUDED_PATHS.to_vec()
}

pub fn default_codex_dir() -> Result<PathBuf> {
    Ok(BaseDirs::new()
        .context("could not resolve user home directory")?
        .home_dir()
        .join(".codex"))
}

pub fn app_root() -> Result<PathBuf> {
    Ok(project_dirs()
        .context("could not resolve platform data directory")?
        .data_dir()
        .to_path_buf())
}

pub fn default_env_file() -> Result<PathBuf> {
    let cwd_env = env::current_dir()
        .context("could not resolve current directory")?
        .join(".env");
    if cwd_env.exists() {
        return Ok(cwd_env);
    }

    Ok(app_root()?.join(".env"))
}

pub fn staging_root() -> Result<PathBuf> {
    Ok(app_root()?.join("staging"))
}

pub fn restore_root() -> Result<PathBuf> {
    Ok(app_root()?.join("restore"))
}

pub fn rollback_root() -> Result<PathBuf> {
    Ok(app_root()?.join("rollback"))
}

pub fn log_root() -> Result<PathBuf> {
    Ok(app_root()?.join("logs"))
}

pub fn platform_tag() -> &'static str {
    match env::consts::OS {
        "windows" => "windows",
        "macos" => "macos",
        "linux" => "linux",
        other => other,
    }
}

fn project_dirs() -> Option<ProjectDirs> {
    ProjectDirs::from("com", "openai", "codex-backup")
}
