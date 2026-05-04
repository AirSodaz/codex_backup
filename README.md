# Codex R2 Backup

[中文说明](README.zh-CN.md)

Cross-platform Rust CLI for backing up local Codex history, memories, and SQLite
state to Cloudflare R2 through Restic.

## What Gets Backed Up

Included from the default Codex directory at `~/.codex`:

- `sessions`
- `archived_sessions`
- `session_index.jsonl`
- `history.jsonl`
- `memories`
- root `logs_*.sqlite` and `state_*.sqlite` files through SQLite online backup

Intentionally excluded:

- `auth.json`
- `.sandbox-secrets`
- cache, temp, plugin cache, sandbox, vendor import, and worktree directories

The CLI stages a clean backup directory first. Active SQLite databases are not
copied directly; each managed root SQLite file is captured with SQLite's online
backup API.

## Setup

Run the installer from the repository root.

Windows:

```powershell
.\scripts\install.ps1
```

macOS and Linux:

```sh
chmod +x scripts/install.sh
./scripts/install.sh
```

The installer checks or installs Rust, Restic, and the `codex-backup` CLI. It
then prompts for R2 or `RESTIC_REPOSITORY` settings, writes the private `.env`
file to the platform app data directory, saves the Restic repository password to
the system keyring, and initializes the Restic repository.

Existing `.env` files are preserved by default. Pass `-ForceEnv` on Windows or
`--force-env` on macOS/Linux to replace them. Pass `-SkipInit` or `--skip-init`
to install the CLI without interactive repository setup.

To install the daily backup schedule during setup, opt in explicitly:

```powershell
.\scripts\install.ps1 -InstallSchedule -ScheduleTime 03:00
```

```sh
./scripts/install.sh --install-schedule --schedule-time 03:00
```

For manual development or troubleshooting, install Rust and Restic yourself,
then install the CLI and initialize it:

```powershell
cargo install --path . --locked --force --bin codex-backup
Copy-Item .env.example .env
codex-backup doctor --env-file .env
codex-backup init --set-password --env-file .env
```

Check local readiness:

```powershell
codex-backup doctor
```

The Rust CLI uses the platform credential store by default: Windows Credential
Manager, macOS Keychain, or Linux Secret Service. For CI or headless runs, set
`RESTIC_PASSWORD` or pass `--password-file`.

## Back Up

Run a normal backup:

```powershell
codex-backup backup
```

Run a local staging dry run without Restic upload:

```powershell
codex-backup backup --skip-restic --keep-staging
```

Use a non-default Codex directory for testing:

```powershell
codex-backup backup --skip-restic --keep-staging --codex-dir C:\path\to\.codex
```

Restic snapshots are tagged with `codex` and the current platform tag:
`windows`, `macos`, or `linux`. Retention is applied after successful upload:

- keep 7 daily snapshots
- keep 4 weekly snapshots
- keep 6 monthly snapshots

## Schedule

Install a daily 03:00 backup schedule:

```powershell
codex-backup schedule install --time 03:00
```

Remove the schedule:

```powershell
codex-backup schedule remove
```

The CLI uses the native scheduler for each platform:

- Windows: Task Scheduler through `schtasks.exe`
- macOS: user LaunchAgent
- Linux: systemd user service and timer

## Check Repository

Run snapshots, repository check, and retention pruning:

```powershell
codex-backup check
```

Skip pruning during a read-only check:

```powershell
codex-backup check --skip-prune
```

## Restore

Restore the latest snapshot into a temporary directory only:

```powershell
codex-backup restore
```

Apply a restored snapshot to `~/.codex` only after closing Codex:

```powershell
codex-backup restore --apply
```

Applying a restore moves existing managed files to the platform app data
rollback directory before copying restored files into place. Credentials are
never restored.

## Tests

Run the local Rust test suite:

```powershell
cargo test
```

Run the full local verification set:

```powershell
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```
