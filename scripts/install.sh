#!/usr/bin/env sh
set -eu

skip_deps=0
skip_init=0
force_env=0
dry_run=0
install_schedule=0
schedule_time=03:00
tmp_dir=

usage() {
    cat <<'USAGE'
Usage: scripts/install.sh [options]

Options:
  --skip-deps          Do not install Rust or Restic.
  --skip-init          Do not prompt for .env values or initialize Restic.
  --force-env          Overwrite an existing generated .env file.
  --dry-run            Print commands without executing them.
  --install-schedule   Install the daily native backup schedule.
  --schedule-time HH:MM
                       Time for --install-schedule. Defaults to 03:00.
  -h, --help           Show this help.
USAGE
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '==> %s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

quote_arg() {
    case "$1" in
        ''|*[!A-Za-z0-9_./:=+-]*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

print_command() {
    printf '[dry-run]'
    for arg in "$@"; do
        printf ' '
        quote_arg "$arg"
    done
    printf '\n'
}

run_cmd() {
    if [ "$dry_run" -eq 1 ]; then
        print_command "$@"
    else
        "$@"
    fi
}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        run_cmd "$@"
    else
        command_exists sudo || die "sudo is required to install Restic with the system package manager."
        run_cmd sudo "$@"
    fi
}

cleanup() {
    if [ -n "$tmp_dir" ] && [ "$dry_run" -eq 0 ] && [ -d "$tmp_dir" ]; then
        rm -rf "$tmp_dir"
    fi
}
trap cleanup EXIT INT TERM

validate_time() {
    case "$1" in
        [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9])
            return 0
            ;;
        *)
            die "--schedule-time must use HH:MM with a valid 24-hour time."
            ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-deps)
            skip_deps=1
            ;;
        --skip-init)
            skip_init=1
            ;;
        --force-env)
            force_env=1
            ;;
        --dry-run)
            dry_run=1
            ;;
        --install-schedule)
            install_schedule=1
            ;;
        --schedule-time)
            shift
            [ "$#" -gt 0 ] || die "--schedule-time requires HH:MM."
            schedule_time=$1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
    shift
done

validate_time "$schedule_time"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

add_cargo_path() {
    cargo_bin=$HOME/.cargo/bin
    case ":$PATH:" in
        *":$cargo_bin:"*) ;;
        *) PATH=$cargo_bin:$PATH; export PATH ;;
    esac
}

assert_command() {
    name=$1
    hint=$2
    if [ "$dry_run" -eq 1 ]; then
        return
    fi
    command_exists "$name" || die "$name was not found. $hint"
}

ensure_rust_components() {
    if [ "$skip_deps" -eq 0 ] && command_exists rustup; then
        step "Ensuring the stable Rust toolchain, rustfmt, and clippy are installed"
        run_cmd rustup default stable
        run_cmd rustup component add rustfmt clippy
    fi
}

ensure_rust() {
    add_cargo_path
    if command_exists cargo; then
        ensure_rust_components
        return
    fi

    [ "$skip_deps" -eq 0 ] || die "cargo was not found and --skip-deps was set. Install Rust first, then re-run this script."
    command_exists curl || die "curl is required to install Rust from rustup.rs."

    step "Installing Rust with rustup.rs"
    tmp_dir=${TMPDIR:-/tmp}/codex-backup-install.$$
    run_cmd mkdir -p "$tmp_dir"
    run_cmd curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$tmp_dir/rustup-init.sh"
    run_cmd sh "$tmp_dir/rustup-init.sh" -y --profile minimal
    add_cargo_path
    ensure_rust_components
    assert_command cargo "Install Rust from https://rustup.rs/."
}

install_restic_linux() {
    if command_exists apt-get; then
        run_as_root apt-get update
        run_as_root apt-get install -y restic
    elif command_exists dnf; then
        run_as_root dnf install -y restic
    elif command_exists yum; then
        run_as_root yum install -y restic
    elif command_exists pacman; then
        run_as_root pacman -Sy --noconfirm restic
    elif command_exists zypper; then
        run_as_root zypper --non-interactive install restic
    elif command_exists apk; then
        run_as_root apk add restic
    else
        die "No supported Linux package manager found for Restic."
    fi
}

ensure_restic() {
    if command_exists restic; then
        return
    fi

    [ "$skip_deps" -eq 0 ] || die "restic was not found and --skip-deps was set. Install Restic first, then re-run this script."

    case "$(uname -s)" in
        Darwin)
            command_exists brew || die "Homebrew is required to install Restic on macOS. Install Homebrew, then re-run this script."
            step "Installing Restic with Homebrew"
            run_cmd brew install restic
            ;;
        Linux)
            step "Installing Restic with the system package manager"
            install_restic_linux
            ;;
        *)
            if [ "$dry_run" -eq 1 ]; then
                step "Would install Restic with Homebrew or a supported Linux package manager"
                return
            fi
            die "Unsupported platform. This script supports macOS and Linux."
            ;;
    esac

    assert_command restic "Install Restic from https://restic.net/."
}

install_cli() {
    assert_command cargo "Install Rust from https://rustup.rs/."
    step "Installing codex-backup CLI"
    run_cmd cargo install --path "$repo_root" --locked --force --bin codex-backup
    add_cargo_path
    assert_command codex-backup "Make sure \$HOME/.cargo/bin is on PATH."
}

default_env_path() {
    case "$(uname -s)" in
        Darwin)
            printf '%s\n' "$HOME/Library/Application Support/com.openai.codex-backup/.env"
            ;;
        Linux)
            data_home=${XDG_DATA_HOME:-$HOME/.local/share}
            printf '%s\n' "$data_home/codex-backup/.env"
            ;;
        *)
            if [ "$dry_run" -eq 1 ]; then
                data_home=${XDG_DATA_HOME:-$HOME/.local/share}
                printf '%s\n' "$data_home/codex-backup/.env"
                return
            fi
            die "Unsupported platform. This script supports macOS and Linux."
            ;;
    esac
}

read_secret() {
    prompt=$1
    printf '%s: ' "$prompt" >&2
    old_stty=$(stty -g 2>/dev/null || true)
    stty -echo 2>/dev/null || true
    IFS= read -r value
    if [ -n "$old_stty" ]; then
        stty "$old_stty" 2>/dev/null || true
    fi
    printf '\n' >&2
    printf '%s' "$value"
}

read_required() {
    prompt=$1
    secret=${2:-0}
    while :; do
        if [ "$secret" = "1" ]; then
            value=$(read_secret "$prompt")
        else
            printf '%s: ' "$prompt" >&2
            IFS= read -r value
        fi
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return
        fi
        warn "$prompt is required."
    done
}

read_with_default() {
    prompt=$1
    default=$2
    printf '%s [%s]: ' "$prompt" "$default" >&2
    IFS= read -r value
    if [ -n "$value" ]; then
        printf '%s' "$value"
    else
        printf '%s' "$default"
    fi
}

append_env_line() {
    name=$1
    value=$2
    case "$value" in
        *'
'*)
            die "$name cannot contain a newline."
            ;;
    esac
    printf '%s=%s\n' "$name" "$value" >> "$env_tmp"
}

write_env_file() {
    env_file=$1

    if [ -f "$env_file" ] && [ "$force_env" -eq 0 ]; then
        step "Using existing .env at $env_file"
        return
    fi

    if [ "$dry_run" -eq 1 ]; then
        step "Would prompt for R2/Restic settings and write $env_file"
        return
    fi

    [ -t 0 ] || die "Cannot prompt for .env values because stdin is not interactive. Re-run with --skip-init or create $env_file manually."

    env_dir=$(dirname "$env_file")
    mkdir -p "$env_dir"
    env_tmp=$env_file.tmp
    old_umask=$(umask)
    umask 077
    : > "$env_tmp"
    umask "$old_umask"

    step "Creating .env at $env_file"
    printf '# Generated by scripts/install.sh.\n' >> "$env_tmp"
    printf 'RESTIC_REPOSITORY (leave blank to build it from R2 fields): ' >&2
    IFS= read -r repository

    if [ -n "$repository" ]; then
        append_env_line RESTIC_REPOSITORY "$repository"
        append_env_line R2_ACCESS_KEY_ID "$(read_required R2_ACCESS_KEY_ID)"
        append_env_line R2_SECRET_ACCESS_KEY "$(read_required R2_SECRET_ACCESS_KEY 1)"
        append_env_line R2_REGION "$(read_with_default R2_REGION auto)"
    else
        append_env_line R2_ACCOUNT_ID "$(read_required R2_ACCOUNT_ID)"
        append_env_line R2_BUCKET "$(read_required R2_BUCKET)"
        append_env_line R2_PREFIX "$(read_with_default R2_PREFIX codex/history)"
        printf '\n' >> "$env_tmp"
        append_env_line R2_ACCESS_KEY_ID "$(read_required R2_ACCESS_KEY_ID)"
        append_env_line R2_SECRET_ACCESS_KEY "$(read_required R2_SECRET_ACCESS_KEY 1)"
        append_env_line R2_REGION "$(read_with_default R2_REGION auto)"
    fi

    mv "$env_tmp" "$env_file"
}

initialize_repository() {
    env_file=$1

    if [ "$skip_init" -eq 1 ]; then
        step "Skipping interactive Restic initialization"
        printf 'Run this later: codex-backup init --set-password --env-file %s\n' "$(quote_arg "$env_file")"
        return
    fi

    write_env_file "$env_file"
    assert_command codex-backup "Install the CLI first."

    step "Initializing Restic repository"
    run_cmd codex-backup init --set-password --env-file "$env_file"
}

run_doctor() {
    env_file=$1
    if [ "$dry_run" -eq 1 ] || command_exists codex-backup; then
        step "Checking installation"
        run_cmd codex-backup doctor --env-file "$env_file"
    fi
}

install_schedule_if_requested() {
    env_file=$1

    if [ "$install_schedule" -ne 1 ]; then
        return 0
    fi
    if [ "$dry_run" -eq 0 ] && [ ! -f "$env_file" ]; then
        die "Cannot install a schedule because $env_file does not exist."
    fi

    step "Installing daily backup schedule"
    run_cmd codex-backup schedule install --env-file "$env_file" --time "$schedule_time"
}

add_cargo_path

if [ "$skip_deps" -eq 1 ]; then
    step "Skipping dependency installation"
else
    ensure_rust
    ensure_restic
fi

install_cli
env_path=$(default_env_path)
initialize_repository "$env_path"
run_doctor "$env_path"
install_schedule_if_requested "$env_path"

step "codex-backup installation script finished"
