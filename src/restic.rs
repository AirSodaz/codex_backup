use std::ffi::OsStr;
use std::path::Path;
use std::process::Command;

use anyhow::{bail, Context, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSpec {
    pub program: String,
    pub args: Vec<String>,
}

impl CommandSpec {
    pub fn new(program: impl Into<String>, args: Vec<String>) -> Self {
        Self {
            program: program.into(),
            args,
        }
    }
}

pub fn backup_commands(staging_dir: &Path, platform_tag: &str) -> Vec<CommandSpec> {
    vec![
        CommandSpec::new(
            "restic",
            vec![
                "backup".to_string(),
                path_arg(staging_dir),
                "--tag".to_string(),
                "codex".to_string(),
                "--tag".to_string(),
                platform_tag.to_string(),
            ],
        ),
        retention_command(),
    ]
}

pub fn check_commands(skip_prune: bool) -> Vec<CommandSpec> {
    let mut commands = vec![
        CommandSpec::new(
            "restic",
            vec![
                "snapshots".to_string(),
                "--tag".to_string(),
                "codex".to_string(),
            ],
        ),
        CommandSpec::new("restic", vec!["check".to_string()]),
    ];
    if !skip_prune {
        commands.push(retention_command());
    }
    commands
}

pub fn restore_command(snapshot: &str, target_root: &Path) -> CommandSpec {
    CommandSpec::new(
        "restic",
        vec![
            "restore".to_string(),
            snapshot.to_string(),
            "--target".to_string(),
            path_arg(target_root),
        ],
    )
}

pub fn snapshots_command() -> CommandSpec {
    CommandSpec::new("restic", vec!["snapshots".to_string()])
}

pub fn init_command() -> CommandSpec {
    CommandSpec::new("restic", vec!["init".to_string()])
}

pub fn run(spec: &CommandSpec, envs: &[(String, String)]) -> Result<String> {
    let output = Command::new(&spec.program)
        .args(&spec.args)
        .envs(envs.iter().map(|(key, value)| (key, value)))
        .output()
        .with_context(|| format!("failed to start {}", spec.program))?;

    let mut combined = String::new();
    combined.push_str(&String::from_utf8_lossy(&output.stdout));
    combined.push_str(&String::from_utf8_lossy(&output.stderr));

    if !output.status.success() {
        bail!(
            "{} {} exited with code {:?}: {}",
            spec.program,
            spec.args.join(" "),
            output.status.code(),
            combined.trim()
        );
    }

    Ok(combined)
}

pub fn run_allow_failure(spec: &CommandSpec, envs: &[(String, String)]) -> Result<bool> {
    let output = Command::new(&spec.program)
        .args(&spec.args)
        .envs(envs.iter().map(|(key, value)| (key, value)))
        .output()
        .with_context(|| format!("failed to start {}", spec.program))?;
    Ok(output.status.success())
}

pub fn is_program_available(program: &str) -> bool {
    let path = std::env::var_os("PATH").unwrap_or_default();
    std::env::split_paths(&path).any(|dir| {
        let candidate = dir.join(program);
        candidate.is_file()
            || executable_extensions()
                .iter()
                .any(|extension| dir.join(format!("{program}{extension}")).is_file())
    })
}

fn retention_command() -> CommandSpec {
    CommandSpec::new(
        "restic",
        vec![
            "forget".to_string(),
            "--keep-daily".to_string(),
            "7".to_string(),
            "--keep-weekly".to_string(),
            "4".to_string(),
            "--keep-monthly".to_string(),
            "6".to_string(),
            "--prune".to_string(),
            "--tag".to_string(),
            "codex".to_string(),
        ],
    )
}

fn path_arg(path: &Path) -> String {
    path.as_os_str().to_string_lossy().replace('\\', "/")
}

fn executable_extensions() -> Vec<&'static str> {
    if cfg!(target_os = "windows") {
        vec![".exe", ".cmd", ".bat"]
    } else {
        vec![""]
    }
}

pub fn quoted_command_line(program: &Path, args: &[&str]) -> String {
    std::iter::once(shell_quote(program.as_os_str()))
        .chain(args.iter().map(|arg| shell_quote(OsStr::new(arg))))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_quote(value: &OsStr) -> String {
    let text = value.to_string_lossy();
    if text.contains(' ') || text.contains('"') {
        format!("\"{}\"", text.replace('"', "\\\""))
    } else {
        text.to_string()
    }
}
