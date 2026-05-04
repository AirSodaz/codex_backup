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

1. Install Rust and Restic.

2. Copy `.env.example` to `.env` and fill in the R2 values. Keep `.env` private.

3. Check local readiness:

```powershell
cargo run -- doctor
```

4. Save the Restic repository password to the system keyring and initialize the
   repository:

```powershell
cargo run -- init --set-password
```

The Rust CLI uses the platform credential store by default: Windows Credential
Manager, macOS Keychain, or Linux Secret Service. For CI or headless runs, set
`RESTIC_PASSWORD` or pass `--password-file`.

## Back Up

Run a normal backup:

```powershell
cargo run -- backup
```

Run a local staging dry run without Restic upload:

```powershell
cargo run -- backup --skip-restic --keep-staging
```

Use a non-default Codex directory for testing:

```powershell
cargo run -- backup --skip-restic --keep-staging --codex-dir C:\path\to\.codex
```

Restic snapshots are tagged with `codex` and the current platform tag:
`windows`, `macos`, or `linux`. Retention is applied after successful upload:

- keep 7 daily snapshots
- keep 4 weekly snapshots
- keep 6 monthly snapshots

## Schedule

Install a daily 03:00 backup schedule:

```powershell
cargo run -- schedule install --time 03:00
```

Remove the schedule:

```powershell
cargo run -- schedule remove
```

The CLI uses the native scheduler for each platform:

- Windows: Task Scheduler through `schtasks.exe`
- macOS: user LaunchAgent
- Linux: systemd user service and timer

## Check Repository

Run snapshots, repository check, and retention pruning:

```powershell
cargo run -- check
```

Skip pruning during a read-only check:

```powershell
cargo run -- check --skip-prune
```

## Restore

Restore the latest snapshot into a temporary directory only:

```powershell
cargo run -- restore
```

Apply a restored snapshot to `~/.codex` only after closing Codex:

```powershell
cargo run -- restore --apply
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
