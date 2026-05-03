# Codex R2 Backup

PowerShell tooling for backing up local Codex history, memories, and SQLite state to Cloudflare R2 through Restic.

## What Gets Backed Up

Included from `%USERPROFILE%\.codex`:

- `sessions`
- `archived_sessions`
- `session_index.jsonl`
- `history.jsonl`
- `memories`
- `logs_*.sqlite` and `state_*.sqlite` through `sqlite3 .backup`

Intentionally excluded:

- `auth.json`
- `.sandbox-secrets`
- cache, temp, plugin cache, sandbox, and worktree directories

The scripts stage a clean backup directory first. Active SQLite databases are not copied directly; each root `logs_*.sqlite` and `state_*.sqlite` file is captured with SQLite's online backup command.

## Setup

1. Install or check required tools:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-tools.ps1
```

2. Copy `.env.example` to `.env` and fill in the R2 values. Keep `.env` private.

3. Initialize the Restic repository and save the Restic password with Windows DPAPI:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\init-repo.ps1
```

## Back Up

Run a normal backup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\backup-codex.ps1
```

Run a local staging dry run without Restic upload:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\backup-codex.ps1 -SkipRestic -KeepStaging
```

Restic retention is applied after successful upload:

- keep 7 daily snapshots
- keep 4 weekly snapshots
- keep 6 monthly snapshots

## Schedule

Register a daily 03:00 Windows scheduled task:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\register-schedule.ps1
```

## Check Repository

Run snapshots, repository check, and retention pruning:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-repo.ps1
```

Skip pruning during a read-only check:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-repo.ps1 -SkipPrune
```

## Restore

Restore the latest snapshot into a temporary directory only:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore-codex.ps1
```

Apply a restored snapshot to `%USERPROFILE%\.codex` only after closing Codex:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore-codex.ps1 -Apply
```

Applying a restore moves existing managed files to `%APPDATA%\codex-backup\rollback` before copying restored files into place. Credentials are never restored.

## Tests

Run the local test suite:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```
