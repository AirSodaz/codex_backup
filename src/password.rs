use std::env;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use keyring::Entry;

const SERVICE: &str = "codex-backup";
const USER: &str = "restic";

pub fn save_restic_password(password: &str) -> Result<()> {
    keyring_entry()?
        .set_password(password)
        .context("failed to save Restic password to the system keyring")
}

pub fn get_restic_password(password_file: Option<&Path>) -> Result<String> {
    if let Ok(password) = env::var("RESTIC_PASSWORD") {
        if !password.trim().is_empty() {
            return Ok(password);
        }
    }

    if let Some(password_file) = password_file {
        return read_password_file(password_file);
    }

    if let Ok(password_file) = env::var("RESTIC_PASSWORD_FILE") {
        if !password_file.trim().is_empty() {
            return read_password_file(Path::new(&password_file));
        }
    }

    keyring_entry()?
        .get_password()
        .context("failed to read Restic password from the system keyring; run `codex-backup init --set-password` or set RESTIC_PASSWORD")
}

pub fn keyring_available() -> bool {
    keyring_entry().is_ok()
}

fn keyring_entry() -> Result<Entry> {
    Entry::new(SERVICE, USER).context("failed to open system keyring entry")
}

fn read_password_file(path: &Path) -> Result<String> {
    Ok(fs::read_to_string(path)
        .with_context(|| format!("failed to read Restic password file {}", path.display()))?
        .trim_end_matches(['\r', '\n'])
        .to_string())
}
