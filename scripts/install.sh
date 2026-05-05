#!/usr/bin/env sh
set -eu

install_mode=release
release_version=latest
update=0
skip_deps=0
skip_init=0
force_env=0
dry_run=0
yes=0
install_schedule=0
schedule_time=03:00
tmp_dir=
explicit_install_mode=0
explicit_release_version=0
explicit_skip_init=0
explicit_install_schedule=0
explicit_schedule_time=0

github_repository=AirSodaz/codex_backup
release_api_base=https://api.github.com/repos/$github_repository/releases

usage() {
    cat <<'USAGE'
Usage: scripts/install.sh [options]

Options:
  --install-mode MODE  Install the CLI from release or source. Defaults to release.
  --release-version V  GitHub release tag to install, or latest. Defaults to latest.
  --update             Refresh only the codex-backup CLI and run doctor.
  --skip-deps          Do not install Rust or Restic.
  --skip-init          Do not prompt for .env values or initialize Restic.
  --force-env          Overwrite an existing generated .env file.
  --dry-run            Print commands without executing them.
  --yes                Use safe defaults without prompting.
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

die_release() {
    die "$* Re-run with --install-mode source to build from source with Rust."
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
        case "$tmp_dir" in
            "${TMPDIR:-/tmp}"/codex-backup-install.*)
                rm -rf "$tmp_dir"
                ;;
        esac
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

validate_install_mode() {
    case "$install_mode" in
        release|source)
            return 0
            ;;
        *)
            die "--install-mode must be release or source."
            ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-mode)
            shift
            [ "$#" -gt 0 ] || die "--install-mode requires release or source."
            install_mode=$1
            explicit_install_mode=1
            ;;
        --release-version)
            shift
            [ "$#" -gt 0 ] || die "--release-version requires latest or a tag such as v0.1.0."
            release_version=$1
            explicit_release_version=1
            ;;
        --update)
            update=1
            ;;
        --skip-deps)
            skip_deps=1
            ;;
        --skip-init)
            skip_init=1
            explicit_skip_init=1
            ;;
        --force-env)
            force_env=1
            ;;
        --dry-run)
            dry_run=1
            ;;
        --yes)
            yes=1
            ;;
        --install-schedule)
            install_schedule=1
            explicit_install_schedule=1
            ;;
        --schedule-time)
            shift
            [ "$#" -gt 0 ] || die "--schedule-time requires HH:MM."
            schedule_time=$1
            explicit_schedule_time=1
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

validate_install_mode
validate_time "$schedule_time"

validate_update_mode_options() {
    [ "$update" -eq 1 ] || return 0

    [ "$force_env" -eq 0 ] ||
        die "Update mode cannot be combined with --force-env because update mode does not rewrite .env."
    [ "$install_schedule" -eq 0 ] ||
        die "Update mode cannot be combined with --install-schedule because update mode does not change schedules."
    [ "$explicit_schedule_time" -eq 0 ] ||
        die "Update mode cannot be combined with --schedule-time because update mode does not change schedules."
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

add_path_entry() {
    path_to_add=$1
    case ":$PATH:" in
        *":$path_to_add:"*) ;;
        *) PATH=$path_to_add:$PATH; export PATH ;;
    esac
}

add_cargo_path() {
    add_path_entry "$HOME/.cargo/bin"
}

managed_bin_dir() {
    case "$(uname -s)" in
        Darwin)
            printf '%s\n' "$HOME/Library/Application Support/com.openai.codex-backup/bin"
            ;;
        Linux)
            data_home=${XDG_DATA_HOME:-$HOME/.local/share}
            printf '%s\n' "$data_home/codex-backup/bin"
            ;;
        *)
            if [ "$dry_run" -eq 1 ]; then
                data_home=${XDG_DATA_HOME:-$HOME/.local/share}
                printf '%s\n' "$data_home/codex-backup/bin"
                return
            fi
            die "Unsupported platform. This script supports macOS and Linux."
            ;;
    esac
}

add_managed_bin_path() {
    add_path_entry "$(managed_bin_dir)"
}

double_quote_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'
}

shell_profile_path() {
    if [ -n "${CODEX_BACKUP_PROFILE:-}" ]; then
        printf '%s\n' "$CODEX_BACKUP_PROFILE"
        return
    fi

    shell_name=$(basename "${SHELL:-sh}")
    os_name=$(uname -s)
    case "$shell_name:$os_name" in
        zsh:Darwin)
            printf '%s\n' "$HOME/.zprofile"
            ;;
        zsh:*)
            printf '%s\n' "$HOME/.zshrc"
            ;;
        bash:Darwin)
            printf '%s\n' "$HOME/.bash_profile"
            ;;
        bash:*)
            printf '%s\n' "$HOME/.bashrc"
            ;;
        *)
            printf '%s\n' "$HOME/.profile"
            ;;
    esac
}

ensure_managed_bin_on_path() {
    bin_dir=$(managed_bin_dir)
    if [ "$dry_run" -eq 1 ]; then
        step "Would create $bin_dir and add it to the shell PATH profile"
        return
    fi

    mkdir -p "$bin_dir"
    add_path_entry "$bin_dir"

    profile=$(shell_profile_path)
    profile_dir=$(dirname "$profile")
    mkdir -p "$profile_dir"
    if [ -f "$profile" ] && grep -F '# BEGIN codex-backup PATH' "$profile" >/dev/null 2>&1; then
        return
    fi

    escaped_bin=$(double_quote_escape "$bin_dir")
    {
        printf '\n# BEGIN codex-backup PATH\n'
        printf 'case ":$PATH:" in\n'
        printf '  *":%s:"*) ;;\n' "$escaped_bin"
        printf '  *) PATH="%s:$PATH"; export PATH ;;\n' "$escaped_bin"
        printf 'esac\n'
        printf '# END codex-backup PATH\n'
    } >> "$profile"
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

platform_asset_target() {
    case "$(uname -s):$(uname -m)" in
        Linux:x86_64|Linux:amd64)
            printf '%s\n' linux-x86_64
            ;;
        Linux:aarch64|Linux:arm64)
            printf '%s\n' linux-aarch64
            ;;
        Darwin:x86_64|Darwin:amd64)
            printf '%s\n' macos-x86_64
            ;;
        Darwin:arm64|Darwin:aarch64)
            printf '%s\n' macos-aarch64
            ;;
        MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64)
            [ "$dry_run" -eq 1 ] || die "Use scripts/install.ps1 on Windows."
            printf '%s\n' linux-x86_64
            ;;
        *)
            die "Unsupported platform or architecture: $(uname -s) $(uname -m)."
            ;;
    esac
}

release_api_url() {
    if [ "$release_version" = latest ]; then
        printf '%s\n' "https://api.github.com/repos/$github_repository/releases/latest"
    else
        printf '%s\n' "https://api.github.com/repos/$github_repository/releases/tags/$release_version"
    fi
}

download_file() {
    url=$1
    out_file=$2

    if [ "$dry_run" -eq 1 ]; then
        print_command curl -L --fail -A codex-backup-installer -o "$out_file" "$url"
        return
    fi

    command_exists curl || die_release "curl is required to download codex-backup releases."
    curl -L --fail -A codex-backup-installer -o "$out_file" "$url" || die_release "Failed to download $url."
}

resolve_release_tag() {
    api_url=$(release_api_url)
    release_json=$tmp_dir/release.json
    download_file "$api_url" "$release_json"
    tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$release_json" | head -n 1)
    [ -n "$tag" ] || die_release "Could not resolve release tag from $api_url."
    printf '%s\n' "$tag"
}

verify_checksum() {
    asset_name=$1
    archive_path=$2
    sums_path=$3
    download_dir=$4

    line=$(awk -v asset="$asset_name" '
        {
            name = $NF
            sub(/^\*/, "", name)
            if (name == asset) {
                print
                found = 1
                exit
            }
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$sums_path" || true)

    [ -n "$line" ] || die_release "SHA256SUMS.txt does not contain $asset_name."

    if command_exists sha256sum; then
        printf '%s\n' "$line" | (cd "$download_dir" && sha256sum -c -)
    elif command_exists shasum; then
        expected=$(printf '%s\n' "$line" | awk '{print $1}')
        actual=$(shasum -a 256 "$archive_path" | awk '{print $1}')
        [ "$actual" = "$expected" ] || die_release "Checksum mismatch for $asset_name."
    else
        die_release "sha256sum or shasum is required to verify release downloads."
    fi
}

install_cli_from_release() {
    asset_target=$(platform_asset_target)
    api_url=$(release_api_url)

    if [ "$dry_run" -eq 1 ]; then
        step "Would resolve $release_version GitHub release from $api_url"
        print_command curl -L --fail -A codex-backup-installer "$api_url"
        printf '[dry-run] asset pattern: codex-backup-<version>-%s.tar.gz\n' "$asset_target"
        printf '[dry-run] asset checksum: SHA256SUMS.txt\n'
        ensure_managed_bin_on_path
        return
    fi

    command_exists tar || die_release "tar is required to extract release archives."
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-backup-install.XXXXXX") || die_release "Could not create a temporary install directory."
    tag=$(resolve_release_tag)
    version=${tag#v}
    asset_name=codex-backup-$version-$asset_target.tar.gz
    archive_path=$tmp_dir/$asset_name
    sums_path=$tmp_dir/SHA256SUMS.txt
    extract_dir=$tmp_dir/extract
    mkdir -p "$extract_dir"

    step "Downloading codex-backup $tag release asset for $asset_target"
    download_file "https://github.com/$github_repository/releases/download/$tag/$asset_name" "$archive_path"
    download_file "https://github.com/$github_repository/releases/download/$tag/SHA256SUMS.txt" "$sums_path"

    step "Verifying release checksum"
    verify_checksum "$asset_name" "$archive_path" "$sums_path" "$tmp_dir"

    step "Extracting release archive"
    tar -xzf "$archive_path" -C "$extract_dir" || die_release "Could not extract $asset_name."
    binary_path=$(find "$extract_dir" -type f -name codex-backup | head -n 1)
    [ -n "$binary_path" ] || die_release "Archive $asset_name did not contain codex-backup."

    ensure_managed_bin_on_path
    destination=$(managed_bin_dir)/codex-backup
    cp "$binary_path" "$destination" || die_release "Could not install codex-backup to $destination."
    chmod 0755 "$destination" || die_release "Could not mark $destination executable."
    assert_command codex-backup "Make sure $(managed_bin_dir) is on PATH."
}

install_cli_from_source() {
    assert_command cargo "Install Rust from https://rustup.rs/."
    step "Installing codex-backup CLI from source"
    run_cmd cargo install --path "$repo_root" --locked --force --bin codex-backup
    add_cargo_path
    assert_command codex-backup "Make sure \$HOME/.cargo/bin is on PATH."
}

install_cli() {
    install_cli_binary

    step "Verifying codex-backup CLI startup"
    run_cmd codex-backup doctor
}

install_cli_binary() {
    if [ "$install_mode" = source ]; then
        install_cli_from_source
    else
        install_cli_from_release
    fi
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

read_yes_no_default() {
    prompt=$1
    default=$2
    if [ "$default" = "1" ]; then
        suffix=Y/n
    else
        suffix=y/N
    fi

    while :; do
        printf '%s [%s]: ' "$prompt" "$suffix" >&2
        IFS= read -r value
        case "$value" in
            '')
                [ "$default" = "1" ] && return 0
                return 1
                ;;
            y|Y|yes|YES|Yes)
                return 0
                ;;
            n|N|no|NO|No)
                return 1
                ;;
            *)
                warn "Please answer y or n."
            ;;
        esac
    done
}

is_interactive() {
    [ "$dry_run" -eq 0 ] && [ "$yes" -eq 0 ] && [ -t 0 ] && [ -t 1 ]
}

require_interactive() {
    if ! is_interactive; then
        die "Non-interactive install requires --yes, --skip-init, or explicit parameters."
    fi
}

read_menu_choice() {
    prompt=$1
    default=$2
    choices=$3

    while :; do
        value=$(read_with_default "$prompt" "$default")
        case " $choices " in
            *" $value "*)
                printf '%s' "$value"
                return
                ;;
            *)
                warn "Please choose one of: $choices."
                ;;
        esac
    done
}

write_install_plan_summary() {
    env_file=$1

    step "Installation plan"
    printf '  CLI install source: %s\n' "$install_mode"
    if [ "$install_mode" = release ]; then
        printf '  Release version: %s\n' "$release_version"
        printf '  Managed bin dir: %s\n' "$(managed_bin_dir)"
    else
        printf '  Source checkout: %s\n' "$repo_root"
        printf '  Cargo bin dir: %s\n' "$HOME/.cargo/bin"
    fi
    printf '  Environment file: %s\n' "$env_file"
    if [ "$skip_init" -eq 1 ]; then
        printf '  Initialize repository now: false\n'
    else
        printf '  Initialize repository now: true\n'
    fi
    if [ "$install_schedule" -eq 1 ]; then
        printf '  Install daily backup schedule: true\n'
        printf '  Schedule time: %s\n' "$schedule_time"
    else
        printf '  Install daily backup schedule: false\n'
    fi
}

resolve_interactive_install_plan() {
    env_file=$1

    step "codex-backup interactive installer"
    printf '%s\n' "This wizard installs codex-backup, prepares Restic, and can initialize your repository."
    printf '%s\n' "Defaults: latest GitHub Release, default local Restic repository, no daily schedule."

    if [ "$dry_run" -eq 1 ] || [ "$yes" -eq 1 ]; then
        step "Using default non-interactive install plan where options were not provided"
        write_install_plan_summary "$env_file"
        return
    fi

    require_interactive

    if [ "$explicit_install_mode" -eq 0 ]; then
        step "Select codex-backup CLI install source"
        printf '  1) Latest GitHub Release\n'
        printf '  2) Specific GitHub Release\n'
        printf '  3) Build from source\n'
        choice=$(read_menu_choice "Choose install source" 1 "1 2 3")
        case "$choice" in
            1)
                install_mode=release
                if [ "$explicit_release_version" -eq 0 ]; then
                    release_version=latest
                fi
                ;;
            2)
                install_mode=release
                if [ "$explicit_release_version" -eq 0 ]; then
                    release_version=$(read_required "GitHub release tag (for example v0.1.0)")
                fi
                ;;
            3)
                install_mode=source
                ;;
        esac
    fi

    if [ "$explicit_skip_init" -eq 0 ]; then
        if read_yes_no_default "Initialize the Restic repository now" 1; then
            skip_init=0
        else
            skip_init=1
        fi
    fi

    if [ "$explicit_install_schedule" -eq 0 ]; then
        if read_yes_no_default "Install daily backup schedule" 0; then
            install_schedule=1
        else
            install_schedule=0
        fi
    fi

    if [ "$install_schedule" -eq 1 ] && [ "$explicit_schedule_time" -eq 0 ]; then
        while :; do
            schedule_time=$(read_with_default "Daily backup time (HH:MM)" "$schedule_time")
            case "$schedule_time" in
                [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9])
                    break
                    ;;
                *)
                    warn "Schedule time must use HH:MM with a valid 24-hour time."
                    ;;
            esac
        done
    fi

    write_install_plan_summary "$env_file"
    read_yes_no_default "Proceed with this installation" 1 || die "Installation cancelled."
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
        step "Would prompt with Select Restic repository menu and write $env_file"
        printf '[dry-run] Select Restic repository\n'
        printf '[dry-run] 1) Default local repository\n'
        printf '[dry-run] 2) Custom local repository path\n'
        printf '[dry-run] 3) S3/R2 repository URL\n'
        printf '[dry-run] 4) Legacy Cloudflare R2 fields\n'
        return
    fi

    if [ "$yes" -eq 0 ]; then
        require_interactive
    fi

    env_dir=$(dirname "$env_file")
    mkdir -p "$env_dir"
    env_tmp=$env_file.tmp
    old_umask=$(umask)
    umask 077
    : > "$env_tmp"
    umask "$old_umask"

    step "Creating .env at $env_file"
    printf '# Generated by scripts/install.sh.\n' >> "$env_tmp"
    if [ "$yes" -eq 1 ]; then
        printf '# Default local Restic repository will be used because RESTIC_REPOSITORY is not set.\n' >> "$env_tmp"
    else
        step "Select Restic repository"
        printf '  1) Default local repository\n'
        printf '  2) Custom local repository path\n'
        printf '  3) S3/R2 repository URL\n'
        printf '  4) Legacy Cloudflare R2 fields\n'
        printf '%s\n' "Use default local Restic repository by choosing 1."
        repository_choice=$(read_menu_choice "Choose repository type" 1 "1 2 3 4")

        case "$repository_choice" in
            1)
                printf '# Default local Restic repository will be used because RESTIC_REPOSITORY is not set.\n' >> "$env_tmp"
                ;;
            2)
                append_env_line RESTIC_REPOSITORY "$(read_required "Custom local RESTIC_REPOSITORY path")"
                ;;
            3)
                repository=$(read_required "S3/R2 RESTIC_REPOSITORY URL (must start with s3:)")
                case "$repository" in
                    s3:*) ;;
                    *) die "S3/R2 RESTIC_REPOSITORY must start with s3:." ;;
                esac
                append_env_line RESTIC_REPOSITORY "$repository"
                append_env_line R2_ACCESS_KEY_ID "$(read_required R2_ACCESS_KEY_ID)"
                append_env_line R2_SECRET_ACCESS_KEY "$(read_required R2_SECRET_ACCESS_KEY 1)"
                append_env_line R2_REGION "$(read_with_default R2_REGION auto)"
                ;;
            4)
                append_env_line R2_ACCOUNT_ID "$(read_required R2_ACCOUNT_ID)"
                append_env_line R2_BUCKET "$(read_required R2_BUCKET)"
                append_env_line R2_PREFIX "$(read_with_default R2_PREFIX codex/history)"
                printf '\n' >> "$env_tmp"
                append_env_line R2_ACCESS_KEY_ID "$(read_required R2_ACCESS_KEY_ID)"
                append_env_line R2_SECRET_ACCESS_KEY "$(read_required R2_SECRET_ACCESS_KEY 1)"
                append_env_line R2_REGION "$(read_with_default R2_REGION auto)"
                ;;
        esac
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

update_cli() {
    env_file=$1

    validate_update_mode_options
    step "Update mode only refreshes the codex-backup CLI"
    printf '  CLI install source: %s\n' "$install_mode"
    if [ "$install_mode" = release ]; then
        printf '  Release version: %s\n' "$release_version"
        printf '  Managed bin dir: %s\n' "$(managed_bin_dir)"
    else
        printf '  Source checkout: %s\n' "$repo_root"
        printf '  Cargo bin dir: %s\n' "$HOME/.cargo/bin"
    fi
    printf '  Environment file for doctor: %s\n' "$env_file"

    install_cli_binary
    run_doctor "$env_file"
    step "codex-backup update script finished"
}

add_cargo_path
add_managed_bin_path
env_path=$(default_env_path)

if [ "$update" -eq 1 ]; then
    update_cli "$env_path"
    exit 0
fi

resolve_interactive_install_plan "$env_path"

if [ "$skip_deps" -eq 1 ]; then
    step "Skipping dependency installation"
else
    if [ "$install_mode" = source ]; then
        ensure_rust
    else
        step "Skipping Rust installation because release install mode is selected"
    fi
    ensure_restic
fi

install_cli
initialize_repository "$env_path"
run_doctor "$env_path"
install_schedule_if_requested "$env_path"

step "codex-backup installation script finished"
