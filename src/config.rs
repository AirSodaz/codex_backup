use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BackupConfig {
    values: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepositorySource {
    DefaultLocal,
    ExplicitRepository,
    R2Derived,
}

impl RepositorySource {
    pub fn label(self) -> &'static str {
        match self {
            Self::DefaultLocal => "default local",
            Self::ExplicitRepository => "explicit repository",
            Self::R2Derived => "R2-derived",
        }
    }
}

impl BackupConfig {
    pub fn from_file(path: &Path) -> Result<Self> {
        let contents = fs::read_to_string(path)
            .with_context(|| format!("failed to read environment file {}", path.display()))?;
        Ok(Self::parse(&contents))
    }

    pub fn from_optional_file(path: &Path) -> Result<Self> {
        if path.exists() {
            Self::from_file(path)
        } else {
            Ok(Self::default())
        }
    }

    pub fn from_pairs<I, K, V>(pairs: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        Self {
            values: pairs
                .into_iter()
                .map(|(key, value)| (key.into(), value.into()))
                .collect(),
        }
    }

    pub fn parse(contents: &str) -> Self {
        let mut values = BTreeMap::new();

        for line in contents.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }

            let Some((raw_name, raw_value)) = line.split_once('=') else {
                continue;
            };
            let name = raw_name.trim();
            if name.is_empty() || name.contains('#') {
                continue;
            }

            let value = strip_matching_quotes(raw_value.trim());
            values.insert(name.to_string(), value.to_string());
        }

        Self { values }
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.values
            .get(name)
            .map(String::as_str)
            .filter(|value| !value.trim().is_empty())
    }

    pub fn get_or<'a>(&'a self, name: &str, default: &'a str) -> &'a str {
        self.get(name).unwrap_or(default)
    }

    pub fn require(&self, names: &[&str]) -> Result<()> {
        let missing = names
            .iter()
            .copied()
            .filter(|name| self.get(name).is_none())
            .collect::<Vec<_>>();

        if missing.is_empty() {
            Ok(())
        } else {
            bail!("missing required .env value(s): {}", missing.join(", "))
        }
    }

    pub fn repository_source(&self) -> RepositorySource {
        if let Some(repository) = self.get("RESTIC_REPOSITORY") {
            if !repository.trim().is_empty() {
                return RepositorySource::ExplicitRepository;
            }
        }

        if self.get("R2_BUCKET").is_some()
            || self.get("R2_ACCOUNT_ID").is_some()
            || self.get("R2_ENDPOINT").is_some()
        {
            RepositorySource::R2Derived
        } else {
            RepositorySource::DefaultLocal
        }
    }

    pub fn restic_repository(&self) -> Result<String> {
        self.restic_repository_with_default(&crate::paths::repository_root()?)
    }

    pub fn restic_repository_with_default(&self, default_repository: &Path) -> Result<String> {
        match self.repository_source() {
            RepositorySource::DefaultLocal => Ok(default_repository.display().to_string()),
            RepositorySource::ExplicitRepository => Ok(self
                .get("RESTIC_REPOSITORY")
                .expect("repository source checked above")
                .to_string()),
            RepositorySource::R2Derived => self.r2_repository(),
        }
    }

    pub fn restic_env(&self, password: String) -> Result<Vec<(String, String)>> {
        self.restic_env_with_default(password, &crate::paths::repository_root()?)
    }

    pub fn restic_env_with_default(
        &self,
        password: String,
        default_repository: &Path,
    ) -> Result<Vec<(String, String)>> {
        let repository = self.restic_repository_with_default(default_repository)?;
        let mut envs = vec![("RESTIC_REPOSITORY".to_string(), repository.clone())];

        if self.requires_s3_credentials(&repository) {
            self.require(&["R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"])?;
            envs.extend([
                (
                    "AWS_ACCESS_KEY_ID".to_string(),
                    self.get("R2_ACCESS_KEY_ID")
                        .expect("required above")
                        .to_string(),
                ),
                (
                    "AWS_SECRET_ACCESS_KEY".to_string(),
                    self.get("R2_SECRET_ACCESS_KEY")
                        .expect("required above")
                        .to_string(),
                ),
                (
                    "AWS_DEFAULT_REGION".to_string(),
                    self.get_or("R2_REGION", "auto").to_string(),
                ),
            ]);
        }

        envs.push(("RESTIC_PASSWORD".to_string(), password));
        Ok(envs)
    }

    fn r2_repository(&self) -> Result<String> {
        self.require(&["R2_BUCKET"])?;

        let endpoint = match self.get("R2_ENDPOINT") {
            Some(endpoint) => endpoint.to_string(),
            None => {
                self.require(&["R2_ACCOUNT_ID"])?;
                format!(
                    "https://{}.r2.cloudflarestorage.com",
                    self.get("R2_ACCOUNT_ID").expect("required above")
                )
            }
        };
        let bucket = self.get("R2_BUCKET").expect("required above");
        let prefix = self.get_or("R2_PREFIX", "").trim_matches('/');
        let mut repository = format!("s3:{}/{}", endpoint.trim_end_matches('/'), bucket);

        if !prefix.is_empty() {
            repository.push('/');
            repository.push_str(prefix);
        }

        Ok(repository)
    }

    fn requires_s3_credentials(&self, repository: &str) -> bool {
        self.repository_source() == RepositorySource::R2Derived
            || repository
                .trim_start()
                .to_ascii_lowercase()
                .starts_with("s3:")
    }
}

fn strip_matching_quotes(value: &str) -> &str {
    if value.len() >= 2 {
        let bytes = value.as_bytes();
        let first = bytes[0];
        let last = bytes[value.len() - 1];
        if (first == b'"' && last == b'"') || (first == b'\'' && last == b'\'') {
            return &value[1..value.len() - 1];
        }
    }

    value
}
