use std::fs;
use std::path::Path;

use codex_backup::{
    config::{BackupConfig, RepositorySource},
    paths::{excluded_relative_paths, managed_relative_paths},
    restic::{backup_commands, check_commands, restore_command},
    restore::{apply_restore, ApplyRestoreOptions},
    schedule::{launch_agent_plist, systemd_unit_files, windows_install_command},
    staging::{create_staging, Manifest, StagingOptions},
};
use rusqlite::Connection;
use tempfile::tempdir;

fn write_file(path: &Path, contents: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(path, contents).unwrap();
}

#[test]
fn env_parser_keeps_existing_r2_repository_behavior() {
    let tmp = tempdir().unwrap();
    let env_path = tmp.path().join(".env");
    write_file(
        &env_path,
        r#"
# comment
R2_ACCOUNT_ID = abc123
R2_BUCKET=codex-history
R2_PREFIX="codex/backups/"
R2_ACCESS_KEY_ID='access-key'
R2_SECRET_ACCESS_KEY = secret-value
"#,
    );

    let config = BackupConfig::from_file(&env_path).unwrap();

    assert_eq!(config.get("R2_ACCESS_KEY_ID"), Some("access-key"));
    assert_eq!(
        config.restic_repository().unwrap(),
        "s3:https://abc123.r2.cloudflarestorage.com/codex-history/codex/backups"
    );
}

#[test]
fn explicit_restic_repository_overrides_r2_parts() {
    let config = BackupConfig::from_pairs([
        ("RESTIC_REPOSITORY", "s3:https://example.test/bucket/custom"),
        ("R2_BUCKET", "ignored"),
    ]);

    assert_eq!(
        config.restic_repository().unwrap(),
        "s3:https://example.test/bucket/custom"
    );
}

#[test]
fn missing_env_defaults_to_local_repository_without_r2_credentials() {
    let tmp = tempdir().unwrap();
    let missing_env = tmp.path().join(".env");
    let default_repository = tmp.path().join("repository");

    let config = BackupConfig::from_optional_file(&missing_env).unwrap();

    assert_eq!(config.repository_source(), RepositorySource::DefaultLocal);
    assert_eq!(
        config
            .restic_repository_with_default(&default_repository)
            .unwrap(),
        default_repository.display().to_string()
    );

    let envs = config
        .restic_env_with_default("secret".to_string(), &default_repository)
        .unwrap();
    assert!(envs.iter().any(|(name, value)| {
        name == "RESTIC_REPOSITORY" && value == &default_repository.display().to_string()
    }));
    assert!(envs
        .iter()
        .any(|(name, value)| name == "RESTIC_PASSWORD" && value == "secret"));
    assert!(!envs.iter().any(|(name, _)| name == "AWS_ACCESS_KEY_ID"));
    assert!(!envs.iter().any(|(name, _)| name == "AWS_SECRET_ACCESS_KEY"));
}

#[test]
fn explicit_local_repository_does_not_require_r2_credentials() {
    let default_repository = Path::new("/ignored/default");
    let config = BackupConfig::from_pairs([("RESTIC_REPOSITORY", "/tmp/codex-local-repo")]);

    assert_eq!(
        config.repository_source(),
        RepositorySource::ExplicitRepository
    );
    assert_eq!(
        config
            .restic_repository_with_default(default_repository)
            .unwrap(),
        "/tmp/codex-local-repo"
    );

    let envs = config
        .restic_env_with_default("secret".to_string(), default_repository)
        .unwrap();
    assert!(envs
        .iter()
        .any(|(name, value)| name == "RESTIC_REPOSITORY" && value == "/tmp/codex-local-repo"));
    assert!(!envs.iter().any(|(name, _)| name == "AWS_ACCESS_KEY_ID"));
}

#[test]
fn explicit_s3_repository_requires_r2_credentials() {
    let default_repository = Path::new("/ignored/default");
    let config =
        BackupConfig::from_pairs([("RESTIC_REPOSITORY", "s3:https://example.test/bucket")]);

    let error = config
        .restic_env_with_default("secret".to_string(), default_repository)
        .unwrap_err()
        .to_string();

    assert!(error.contains("R2_ACCESS_KEY_ID"));
    assert!(error.contains("R2_SECRET_ACCESS_KEY"));
}

#[test]
fn managed_and_excluded_paths_match_legacy_scope() {
    assert_eq!(
        managed_relative_paths(),
        vec![
            "sessions",
            "archived_sessions",
            "memories",
            "session_index.jsonl",
            "history.jsonl"
        ]
    );

    assert!(excluded_relative_paths().contains(&"auth.json"));
    assert!(excluded_relative_paths().contains(&".sandbox-secrets"));
    assert!(excluded_relative_paths().contains(&"plugins/cache"));
    assert!(excluded_relative_paths().contains(&"worktrees"));
}

#[test]
fn staging_copies_managed_files_excludes_secrets_and_uses_sqlite_backup() {
    let tmp = tempdir().unwrap();
    let source = tmp.path().join("source");
    let work_root = tmp.path().join("work");

    write_file(&source.join("sessions/2026/05/rollout.jsonl"), "session");
    write_file(&source.join("archived_sessions/old.jsonl"), "archived");
    write_file(&source.join("memories/MEMORY.md"), "memory");
    write_file(&source.join("session_index.jsonl"), "index");
    write_file(&source.join("history.jsonl"), "history");
    write_file(&source.join("auth.json"), "secret");
    write_file(&source.join(".sandbox-secrets/secret.txt"), "secret");
    write_file(&source.join("cache/blob.bin"), "cache");

    let state_db = source.join("state_5.sqlite");
    let logs_db = source.join("logs_2.sqlite");
    let conn = Connection::open(&state_db).unwrap();
    conn.execute_batch(
        "CREATE TABLE state(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO state(value) VALUES('ok');",
    )
    .unwrap();
    let conn = Connection::open(&logs_db).unwrap();
    conn.execute_batch(
        "CREATE TABLE logs(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO logs(value) VALUES('ok');",
    )
    .unwrap();

    let result = create_staging(StagingOptions {
        codex_dir: source.clone(),
        work_root,
        timestamp: "20260504-010203".to_string(),
    })
    .unwrap();

    assert!(result
        .staging_dir
        .join("sessions/2026/05/rollout.jsonl")
        .exists());
    assert!(result
        .staging_dir
        .join("archived_sessions/old.jsonl")
        .exists());
    assert!(result.staging_dir.join("memories/MEMORY.md").exists());
    assert!(result.staging_dir.join("session_index.jsonl").exists());
    assert!(result.staging_dir.join("history.jsonl").exists());
    assert!(result.staging_dir.join("sqlite/state_5.sqlite").exists());
    assert!(result.staging_dir.join("sqlite/logs_2.sqlite").exists());
    assert!(!result.staging_dir.join("auth.json").exists());
    assert!(!result.staging_dir.join(".sandbox-secrets").exists());
    assert!(!result.staging_dir.join("cache").exists());

    let manifest: Manifest =
        serde_json::from_str(&fs::read_to_string(&result.manifest_path).unwrap()).unwrap();
    assert_eq!(manifest.schema_version, 1);
    assert_eq!(manifest.backup_name, "codex-history");
    assert!(manifest.included_paths.contains(&"sessions".to_string()));
    assert!(manifest.excluded_paths.contains(&"auth.json".to_string()));
    assert_eq!(manifest.sqlite_backups.len(), 2);

    let backup = Connection::open(result.staging_dir.join("sqlite/state_5.sqlite")).unwrap();
    let value: String = backup
        .query_row("SELECT value FROM state", [], |row| row.get(0))
        .unwrap();
    assert_eq!(value, "ok");
}

#[test]
fn restore_apply_rolls_back_managed_files_and_sqlite_sidecars() {
    let tmp = tempdir().unwrap();
    let restored = tmp.path().join("restored");
    let codex_dir = tmp.path().join(".codex");
    let rollback_root = tmp.path().join("rollback");

    write_file(&restored.join("sessions/new.jsonl"), "new session");
    write_file(&restored.join("history.jsonl"), "new history");
    write_file(&restored.join("sqlite/state_5.sqlite"), "new sqlite");
    write_file(&codex_dir.join("sessions/old.jsonl"), "old session");
    write_file(&codex_dir.join("history.jsonl"), "old history");
    write_file(&codex_dir.join("state_5.sqlite"), "old sqlite");
    write_file(&codex_dir.join("state_5.sqlite-wal"), "old wal");
    write_file(&codex_dir.join("state_5.sqlite-shm"), "old shm");

    let manifest = Manifest::for_test(
        vec!["sessions".to_string(), "history.jsonl".to_string()],
        vec![(
            "state_5.sqlite".to_string(),
            "sqlite/state_5.sqlite".to_string(),
        )],
    );
    write_file(
        &restored.join("manifest.json"),
        &serde_json::to_string_pretty(&manifest).unwrap(),
    );

    let result = apply_restore(ApplyRestoreOptions {
        restored_staging_dir: restored,
        codex_dir: codex_dir.clone(),
        rollback_root,
        check_processes: false,
        timestamp: "20260504-020304".to_string(),
    })
    .unwrap();

    assert_eq!(
        fs::read_to_string(codex_dir.join("sessions/new.jsonl")).unwrap(),
        "new session"
    );
    assert_eq!(
        fs::read_to_string(codex_dir.join("history.jsonl")).unwrap(),
        "new history"
    );
    assert_eq!(
        fs::read_to_string(codex_dir.join("state_5.sqlite")).unwrap(),
        "new sqlite"
    );
    assert!(result.rollback_dir.join("sessions/old.jsonl").exists());
    assert!(result.rollback_dir.join("history.jsonl").exists());
    assert!(result.rollback_dir.join("state_5.sqlite").exists());
    assert!(result.rollback_dir.join("state_5.sqlite-wal").exists());
    assert!(result.rollback_dir.join("state_5.sqlite-shm").exists());
}

#[test]
fn restic_command_specs_keep_tags_and_retention_rules_cross_platform() {
    let staging_dir = Path::new("/tmp/codex-stage");

    let commands = backup_commands(staging_dir, "linux");

    assert_eq!(commands[0].program, "restic");
    assert_eq!(
        commands[0].args,
        vec![
            "backup",
            "/tmp/codex-stage",
            "--tag",
            "codex",
            "--tag",
            "linux"
        ]
    );
    assert_eq!(
        commands[1].args,
        vec![
            "forget",
            "--keep-daily",
            "7",
            "--keep-weekly",
            "4",
            "--keep-monthly",
            "6",
            "--prune",
            "--tag",
            "codex"
        ]
    );

    assert_eq!(
        check_commands(true)[0].args,
        vec!["snapshots", "--tag", "codex"]
    );
    assert_eq!(check_commands(true)[1].args, vec!["check"]);
    assert_eq!(
        restore_command("latest", Path::new("/tmp/restore")).args,
        vec!["restore", "latest", "--target", "/tmp/restore"]
    );
}

#[test]
fn scheduler_generators_cover_windows_launchd_and_systemd() {
    let exe = Path::new("/opt/codex-backup");
    let env = Path::new("/home/alice/.config/codex-backup/.env");

    let windows = windows_install_command("Codex History Backup", "03:00", exe, env);
    assert_eq!(windows.program, "schtasks.exe");
    assert!(windows.args.contains(&"/SC".to_string()));
    assert!(windows.args.contains(&"DAILY".to_string()));
    assert!(windows.args.contains(&"/ST".to_string()));
    assert!(windows.args.contains(&"03:00".to_string()));

    let plist = launch_agent_plist("com.openai.codex-backup", "03:00", exe, env);
    assert!(plist.contains("<key>ProgramArguments</key>"));
    assert!(plist.contains("<integer>3</integer>"));
    assert!(plist.contains("<integer>0</integer>"));
    assert!(plist.contains("--env-file"));

    let systemd = systemd_unit_files("codex-backup", "03:00", exe, env);
    assert!(systemd
        .service
        .contains("ExecStart=/opt/codex-backup backup --env-file"));
    assert!(systemd
        .service
        .contains("Back up Codex history and SQLite snapshots with Restic"));
    assert!(!systemd.service.contains("Cloudflare R2"));
    assert!(systemd.timer.contains("OnCalendar=*-*-* 03:00:00"));
    assert!(systemd.timer.contains("Persistent=true"));
}

#[test]
fn install_scripts_expose_planned_interfaces() {
    let repo_root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let windows = fs::read_to_string(repo_root.join("scripts/install.ps1")).unwrap();
    let unix = fs::read_to_string(repo_root.join("scripts/install.sh")).unwrap();
    let git_attributes = fs::read_to_string(repo_root.join(".gitattributes")).unwrap();

    for flag in [
        "SkipDeps",
        "SkipInit",
        "ForceEnv",
        "DryRun",
        "Yes",
        "InstallSchedule",
        "ScheduleTime",
        "InstallMode",
        "ReleaseVersion",
        "Update",
    ] {
        assert!(windows.contains(flag), "install.ps1 missing {flag}");
    }

    for flag in [
        "--skip-deps",
        "--skip-init",
        "--force-env",
        "--dry-run",
        "--yes",
        "--install-schedule",
        "--schedule-time",
        "--install-mode",
        "--release-version",
        "--update",
    ] {
        assert!(unix.contains(flag), "install.sh missing {flag}");
    }

    assert!(windows.contains("ValidateSet(\"Release\", \"Source\")"));
    assert!(windows.contains("AirSodaz/codex_backup"));
    assert!(windows.contains("releases/latest"));
    assert!(windows.contains("SHA256SUMS.txt"));
    assert!(windows.contains("windows-x86_64"));
    assert!(windows.contains("windows-aarch64"));
    assert!(windows.contains("codex-backup\\bin"));
    assert!(windows.contains("Expand-Archive"));
    assert!(windows.contains("Get-FileHash"));
    assert!(windows.contains("codex-backup interactive installer"));
    assert!(windows.contains("1) Latest GitHub Release"));
    assert!(windows.contains("2) Specific GitHub Release"));
    assert!(windows.contains("3) Build from source"));
    assert!(windows.contains("Select Restic repository"));
    assert!(windows.contains("1) Default local repository"));
    assert!(windows.contains("2) Custom local repository path"));
    assert!(windows.contains("3) S3/R2 repository URL"));
    assert!(windows.contains("4) Legacy Cloudflare R2 fields"));
    assert!(windows.contains("Install daily backup schedule"));
    assert!(windows.contains("Non-interactive install requires -Yes"));
    assert!(windows.contains("Using default non-interactive install plan"));
    assert!(windows.contains("Use default local Restic repository"));
    assert!(windows.contains("Default local Restic repository"));
    assert!(windows.contains("StartsWith(\"s3:\""));
    assert!(windows.contains("Update mode only refreshes the codex-backup CLI"));
    assert!(windows.contains("Update mode cannot be combined with -ForceEnv"));
    assert!(windows.contains("Update mode cannot be combined with -InstallSchedule"));
    assert!(windows.contains("codex-backup update script finished"));

    assert!(unix.contains("install_mode=release"));
    assert!(unix.contains("AirSodaz/codex_backup"));
    assert!(unix.contains("releases/latest"));
    assert!(unix.contains("SHA256SUMS.txt"));
    assert!(unix.contains("linux-x86_64"));
    assert!(unix.contains("linux-aarch64"));
    assert!(unix.contains("macos-x86_64"));
    assert!(unix.contains("macos-aarch64"));
    assert!(unix.contains("BEGIN codex-backup PATH"));
    assert!(unix.contains("sha256sum -c"));
    assert!(unix.contains("codex-backup interactive installer"));
    assert!(unix.contains("1) Latest GitHub Release"));
    assert!(unix.contains("2) Specific GitHub Release"));
    assert!(unix.contains("3) Build from source"));
    assert!(unix.contains("Select Restic repository"));
    assert!(unix.contains("1) Default local repository"));
    assert!(unix.contains("2) Custom local repository path"));
    assert!(unix.contains("3) S3/R2 repository URL"));
    assert!(unix.contains("4) Legacy Cloudflare R2 fields"));
    assert!(unix.contains("Install daily backup schedule"));
    assert!(unix.contains("Non-interactive install requires --yes"));
    assert!(unix.contains("Using default non-interactive install plan"));
    assert!(unix.contains("Use default local Restic repository"));
    assert!(unix.contains("Default local Restic repository"));
    assert!(unix.contains("s3:*"));
    assert!(unix.contains("Update mode only refreshes the codex-backup CLI"));
    assert!(unix.contains("Update mode cannot be combined with --force-env"));
    assert!(unix.contains("Update mode cannot be combined with --install-schedule"));
    assert!(unix.contains("codex-backup update script finished"));

    assert!(windows.contains("Rustlang.Rustup"));
    assert!(windows.contains("restic.restic"));
    assert!(unix.contains("rustup.rs"));
    assert!(unix.contains("brew install restic"));
    assert!(unix.contains("cargo install --path"));
    assert!(windows.contains("Invoke-External \"cargo\""));
    assert!(windows.contains("\"install\""));
    assert!(windows.contains("\"--path\""));
    assert!(git_attributes.contains("*.sh text eol=lf"));
}
