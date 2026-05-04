use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result};
use chrono::Local;
use clap::{Args, Parser, Subcommand};

use crate::config::BackupConfig;
use crate::password::{get_restic_password, keyring_available, save_restic_password};
use crate::paths;
use crate::restic::{
    backup_commands, check_commands, init_command, is_program_available, restore_command,
    run as run_restic, run_allow_failure, snapshots_command,
};
use crate::restore::{apply_restore, find_restored_staging, ApplyRestoreOptions};
use crate::schedule::{install_schedule, remove_schedule};
use crate::staging::{create_staging, StagingOptions};

#[derive(Debug, Parser)]
#[command(name = "codex-backup")]
#[command(about = "Cross-platform Codex history backup tooling for Restic and Cloudflare R2")]
pub struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Init(InitArgs),
    Backup(BackupArgs),
    Restore(RestoreArgs),
    Check(CheckArgs),
    Doctor(CommonArgs),
    Schedule(ScheduleArgs),
}

#[derive(Debug, Args, Clone)]
struct CommonArgs {
    #[arg(long)]
    env_file: Option<PathBuf>,
    #[arg(long)]
    password_file: Option<PathBuf>,
    #[arg(long)]
    codex_dir: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct InitArgs {
    #[command(flatten)]
    common: CommonArgs,
    #[arg(long)]
    set_password: bool,
}

#[derive(Debug, Args)]
struct BackupArgs {
    #[command(flatten)]
    common: CommonArgs,
    #[arg(long)]
    work_root: Option<PathBuf>,
    #[arg(long)]
    skip_restic: bool,
    #[arg(long)]
    keep_staging: bool,
}

#[derive(Debug, Args)]
struct RestoreArgs {
    #[command(flatten)]
    common: CommonArgs,
    #[arg(long, default_value = "latest")]
    snapshot: String,
    #[arg(long)]
    target_root: Option<PathBuf>,
    #[arg(long)]
    rollback_root: Option<PathBuf>,
    #[arg(long)]
    apply: bool,
}

#[derive(Debug, Args)]
struct CheckArgs {
    #[command(flatten)]
    common: CommonArgs,
    #[arg(long)]
    skip_prune: bool,
}

#[derive(Debug, Args)]
struct ScheduleArgs {
    #[command(subcommand)]
    command: ScheduleCommand,
}

#[derive(Debug, Subcommand)]
enum ScheduleCommand {
    Install(ScheduleInstallArgs),
    Remove(ScheduleRemoveArgs),
}

#[derive(Debug, Args)]
struct ScheduleInstallArgs {
    #[command(flatten)]
    common: CommonArgs,
    #[arg(long, default_value = "03:00")]
    time: String,
    #[arg(long)]
    task_name: Option<String>,
}

#[derive(Debug, Args)]
struct ScheduleRemoveArgs {
    #[arg(long)]
    task_name: Option<String>,
}

pub fn run() -> Result<()> {
    run_with(Cli::parse())
}

pub fn run_with(cli: Cli) -> Result<()> {
    match cli.command {
        Command::Init(args) => init(args),
        Command::Backup(args) => backup(args),
        Command::Restore(args) => restore(args),
        Command::Check(args) => check(args),
        Command::Doctor(args) => doctor(args),
        Command::Schedule(args) => schedule(args),
    }
}

fn init(args: InitArgs) -> Result<()> {
    if args.set_password {
        let password = rpassword::prompt_password("Restic repository password: ")?;
        save_restic_password(&password)?;
        println!("Saved Restic password to the system keyring.");
    }

    let env_file = resolve_env_file(&args.common)?;
    let config = BackupConfig::from_file(&env_file)?;
    let envs = config.restic_env(get_restic_password(args.common.password_file.as_deref())?)?;
    println!("Restic repository: {}", config.restic_repository()?);

    if run_allow_failure(&snapshots_command(), &envs)? {
        println!("Restic repository is already initialized.");
        return Ok(());
    }

    println!("Repository check did not succeed; attempting restic init.");
    run_restic(&init_command(), &envs)?;
    println!("Restic repository initialized.");
    Ok(())
}

fn backup(args: BackupArgs) -> Result<()> {
    let codex_dir = resolve_codex_dir(&args.common)?;
    let work_root = args.work_root.unwrap_or(paths::staging_root()?);
    let timestamp = timestamp();
    let staging = create_staging(StagingOptions {
        codex_dir,
        work_root,
        timestamp,
    })?;
    println!("Staging ready: {}", staging.staging_dir.display());

    if args.skip_restic {
        println!("{}", staging.staging_dir.display());
        return Ok(());
    }

    let env_file = resolve_env_file(&args.common)?;
    let config = BackupConfig::from_file(&env_file)?;
    let envs = config.restic_env(get_restic_password(args.common.password_file.as_deref())?)?;

    for command in backup_commands(&staging.staging_dir, paths::platform_tag()) {
        println!("Running: {} {}", command.program, command.args.join(" "));
        let output = run_restic(&command, &envs)?;
        print!("{output}");
    }

    if !args.keep_staging {
        fs::remove_dir_all(&staging.staging_dir).with_context(|| {
            format!(
                "failed to remove staging dir {}",
                staging.staging_dir.display()
            )
        })?;
    }

    println!("Backup complete.");
    Ok(())
}

fn restore(args: RestoreArgs) -> Result<()> {
    let target_root = args.target_root.unwrap_or(paths::restore_root()?);
    let restore_run_root = target_root.join(format!("restore-{}", timestamp()));
    fs::create_dir_all(&restore_run_root)
        .with_context(|| format!("failed to create {}", restore_run_root.display()))?;

    let env_file = resolve_env_file(&args.common)?;
    let config = BackupConfig::from_file(&env_file)?;
    let envs = config.restic_env(get_restic_password(args.common.password_file.as_deref())?)?;
    let command = restore_command(&args.snapshot, &restore_run_root);
    println!("Running: {} {}", command.program, command.args.join(" "));
    let output = run_restic(&command, &envs)?;
    print!("{output}");

    let restored_staging = find_restored_staging(&restore_run_root)?;
    println!("Restored snapshot staging: {}", restored_staging.display());

    if !args.apply {
        println!(
            "Restore completed to a temporary directory only. Re-run with --apply after closing Codex."
        );
        return Ok(());
    }

    let result = apply_restore(ApplyRestoreOptions {
        restored_staging_dir: restored_staging,
        codex_dir: resolve_codex_dir(&args.common)?,
        rollback_root: args.rollback_root.unwrap_or(paths::rollback_root()?),
        check_processes: true,
        timestamp: timestamp(),
    })?;
    println!("Applied restore to {}", result.codex_dir.display());
    println!(
        "Previous managed files were moved to {}",
        result.rollback_dir.display()
    );
    Ok(())
}

fn check(args: CheckArgs) -> Result<()> {
    let env_file = resolve_env_file(&args.common)?;
    let config = BackupConfig::from_file(&env_file)?;
    let envs = config.restic_env(get_restic_password(args.common.password_file.as_deref())?)?;

    for command in check_commands(args.skip_prune) {
        println!("Running: {} {}", command.program, command.args.join(" "));
        let output = run_restic(&command, &envs)?;
        print!("{output}");
    }

    println!("Repository check complete.");
    Ok(())
}

fn doctor(args: CommonArgs) -> Result<()> {
    let env_file = resolve_env_file(&args)?;
    let codex_dir = resolve_codex_dir(&args)?;

    println!(
        "restic: {}",
        if is_program_available("restic") {
            "available"
        } else {
            "missing"
        }
    );
    println!(
        ".env: {} ({})",
        if env_file.exists() {
            "found"
        } else {
            "missing"
        },
        env_file.display()
    );
    println!(
        "Codex dir: {} ({})",
        if codex_dir.exists() {
            "found"
        } else {
            "missing"
        },
        codex_dir.display()
    );
    println!(
        "keyring: {}",
        if keyring_available() {
            "available"
        } else {
            "unavailable"
        }
    );
    println!(
        "scheduler: {}",
        if cfg!(any(
            target_os = "windows",
            target_os = "macos",
            target_os = "linux"
        )) {
            "supported"
        } else {
            "unsupported"
        }
    );

    Ok(())
}

fn schedule(args: ScheduleArgs) -> Result<()> {
    match args.command {
        ScheduleCommand::Install(args) => {
            let env_file = resolve_env_file(&args.common)?;
            let executable = std::env::current_exe().context("failed to resolve current exe")?;
            let task_name = args.task_name.unwrap_or_else(default_task_name);
            install_schedule(&task_name, &args.time, &executable, &env_file)?;
            println!("Installed daily schedule '{task_name}' at {}.", args.time);
        }
        ScheduleCommand::Remove(args) => {
            let task_name = args.task_name.unwrap_or_else(default_task_name);
            remove_schedule(&task_name)?;
            println!("Removed schedule '{task_name}'.");
        }
    }
    Ok(())
}

fn resolve_env_file(args: &CommonArgs) -> Result<PathBuf> {
    match &args.env_file {
        Some(path) => Ok(path.clone()),
        None => paths::default_env_file(),
    }
}

fn resolve_codex_dir(args: &CommonArgs) -> Result<PathBuf> {
    match &args.codex_dir {
        Some(path) => Ok(path.clone()),
        None => paths::default_codex_dir(),
    }
}

fn timestamp() -> String {
    Local::now().format("%Y%m%d-%H%M%S").to_string()
}

fn default_task_name() -> String {
    if cfg!(target_os = "windows") {
        "Codex R2 History Backup".to_string()
    } else {
        "codex-backup".to_string()
    }
}
