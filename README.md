# Codex Backup

[中文说明](README.zh-CN.md)

Cross-platform Rust CLI for backing up local Codex history, memories, and SQLite
state to a local Restic repository by default. Remote Restic repositories such
as Cloudflare R2/S3 remain supported through optional configuration.

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

During staging, symlinks under managed paths are skipped instead of followed.
Regular files under managed paths larger than 256 MiB are also skipped. Both
cases are recorded in `manifest.json` under `warnings` so you can inspect what
was intentionally left out. Root `logs_*.sqlite` and `state_*.sqlite` files are
still captured through SQLite's online backup path.

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

The installer now starts as an interactive wizard. It shows the target paths,
lets you choose the CLI source, asks how to configure the Restic repository,
and asks whether to initialize the repository and install a daily backup
schedule before it changes anything. The safe defaults are the latest matching
`codex-backup` GitHub Release, the managed install directory on PATH, the
default local Restic repository, repository initialization, and no daily
schedule. Rust is not required for the default release-based install.

Existing `.env` files are preserved by default. Pass `-ForceEnv` on Windows or
`--force-env` on macOS/Linux to replace them. Pass `-SkipInit` or `--skip-init`
to install the CLI without repository setup. For CI or unattended installs,
combine the safe defaults with `-Yes` / `--yes` and usually `-SkipInit` /
`--skip-init` so the Restic password prompt is deferred:

```powershell
.\scripts\install.ps1 -Yes -SkipInit
```

```sh
./scripts/install.sh --yes --skip-init
```

To pin a release, pass `-ReleaseVersion v0.1.0` on Windows or
`--release-version v0.1.0` on macOS/Linux.

To update an existing install without touching repository configuration,
initialization, dependencies, or schedules, use update mode. It always
reinstalls the requested CLI target and then runs `doctor` with the default
environment file:

```powershell
.\scripts\install.ps1 -Update
.\scripts\install.ps1 -Update -ReleaseVersion v0.1.0
```

```sh
./scripts/install.sh --update
./scripts/install.sh --update --release-version v0.1.0
```

To build the CLI locally from source instead of downloading a release, opt in to
source mode. This path installs or checks Rust and then runs `cargo install`:

```powershell
.\scripts\install.ps1 -InstallMode Source
```

```sh
./scripts/install.sh --install-mode source
```

To update from the current checkout instead, combine update mode with source
mode. This requires Rust to already be installed:

```powershell
.\scripts\install.ps1 -Update -InstallMode Source
```

```sh
./scripts/install.sh --update --install-mode source
```

To install the daily backup schedule during setup, opt in explicitly:

```powershell
.\scripts\install.ps1 -InstallSchedule -ScheduleTime 03:00
```

```sh
./scripts/install.sh --install-schedule --schedule-time 03:00
```

For manual development or troubleshooting, install Rust and Restic yourself,
then install the CLI from the current checkout and initialize it:

```powershell
cargo install --path . --locked --force --bin codex-backup
codex-backup doctor
codex-backup init --set-password
```

## Repository Configuration

Without a `.env` file, `codex-backup` uses a default local Restic repository
under the platform app data directory. This is the recommended setup for
syncing history across Codex account switches on the same machine.

To use a specific local repository, create `.env` with:

```dotenv
RESTIC_REPOSITORY=C:\path\to\codex-restic-repository
```

To use Cloudflare R2 or another S3-compatible repository, set:

```dotenv
RESTIC_REPOSITORY=s3:https://your-account-id.r2.cloudflarestorage.com/your-r2-bucket-name/codex/history
R2_ACCESS_KEY_ID=your-r2-access-key-id
R2_SECRET_ACCESS_KEY=your-r2-secret-access-key
R2_REGION=auto
```

Legacy R2 fields are still supported and can build the `s3:` repository URL:

```dotenv
R2_ACCOUNT_ID=your-cloudflare-account-id
R2_BUCKET=your-r2-bucket-name
R2_PREFIX=codex/history
R2_ACCESS_KEY_ID=your-r2-access-key-id
R2_SECRET_ACCESS_KEY=your-r2-secret-access-key
R2_REGION=auto
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

Run a local staging dry run without writing to the Restic repository:

```powershell
codex-backup backup --skip-restic --keep-staging
```

Use a non-default Codex directory for testing:

```powershell
codex-backup backup --skip-restic --keep-staging --codex-dir C:\path\to\.codex
```

Restic snapshots are tagged with `codex` and the current platform tag:
`windows`, `macos`, or `linux`. Retention is applied after a successful write:

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

## Security Boundary

This tool backs up Codex history context and local state only. It does not back
up login credentials, sandbox secrets, caches, or worktrees. The Restic
repository password is independent from any R2/S3 credentials; losing it means
existing encrypted snapshots cannot be restored.

Managed symlinks are never followed, which prevents a backup from accidentally
capturing files outside `~/.codex`. Oversized managed files are skipped with a
manifest warning rather than being silently included.

## Releases

GitHub Actions builds the CLI on every push for Windows x64, Windows ARM64,
Linux x64, Linux ARM64, macOS Intel, and macOS Apple Silicon. Normal branch
pushes publish build artifacts on the workflow run only.

Push a version tag such as `v0.1.0` to create or update a GitHub Release
automatically. Release assets are named
`codex-backup-<version>-<platform>.zip` on Windows and
`codex-backup-<version>-<platform>.tar.gz` on Linux and macOS. Each release also
includes `SHA256SUMS.txt`.

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
