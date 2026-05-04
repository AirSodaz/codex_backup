[CmdletBinding()]
param(
    [ValidateSet("Release", "Source")]
    [string]$InstallMode = "Release",
    [string]$ReleaseVersion = "latest",
    [switch]$SkipDeps,
    [switch]$SkipInit,
    [switch]$ForceEnv,
    [switch]$DryRun,
    [switch]$InstallSchedule,
    [ValidatePattern('^\d{2}:\d{2}$')]
    [string]$ScheduleTime = "03:00"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$GitHubRepository = "AirSodaz/codex_backup"
$ReleaseApiBase = "https://api.github.com/repos/$GitHubRepository/releases"
$GitHubHeaders = @{
    "User-Agent" = "codex-backup-installer"
}

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Write-WarningLine {
    param([string]$Message)
    Write-Warning $Message
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Format-CommandLine {
    param(
        [string]$Program,
        [string[]]$Arguments = @()
    )

    $parts = @($Program) + $Arguments
    return (($parts | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join " ")
}

function Invoke-External {
    param(
        [string]$Program,
        [string[]]$Arguments = @()
    )

    $line = Format-CommandLine -Program $Program -Arguments $Arguments
    if ($DryRun) {
        Write-Host "[dry-run] $line"
        return
    }

    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $line"
    }
}

function Add-PathEntry {
    param([string]$PathToAdd)

    if ([string]::IsNullOrWhiteSpace($PathToAdd)) {
        return
    }

    $parts = @($env:PATH -split ';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not ($parts | Where-Object { $_ -ieq $PathToAdd })) {
        $env:PATH = "$PathToAdd;$env:PATH"
    }
}

function Add-CargoPath {
    Add-PathEntry (Join-Path $HOME ".cargo\bin")
}

function Get-ManagedBinDir {
    $base = if ($env:LOCALAPPDATA) {
        $env:LOCALAPPDATA
    } else {
        Join-Path $HOME "AppData\Local"
    }
    return Join-Path $base "codex-backup\bin"
}

function Add-InstallBinPath {
    Add-PathEntry (Get-ManagedBinDir)
}

function Ensure-InstallBinOnPath {
    $binDir = Get-ManagedBinDir
    if ($DryRun) {
        Write-Step "Would create $binDir and add it to the user PATH"
        return
    }

    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    Add-PathEntry $binDir

    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    $parts = @($userPath -split ';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not ($parts | Where-Object { $_ -ieq $binDir })) {
        $updated = if ([string]::IsNullOrWhiteSpace($userPath)) {
            $binDir
        } else {
            "$binDir;$userPath"
        }
        [Environment]::SetEnvironmentVariable("PATH", $updated, "User")
    }
}

function Refresh-Path {
    $paths = @(
        $env:PATH,
        [Environment]::GetEnvironmentVariable("PATH", "User"),
        [Environment]::GetEnvironmentVariable("PATH", "Machine")
    ) | Where-Object { $_ }
    $env:PATH = ($paths -join ";")
    Add-CargoPath
    Add-InstallBinPath
}

function Assert-Command {
    param(
        [string]$Name,
        [string]$InstallHint
    )

    if ($DryRun) {
        return
    }

    Refresh-Path
    if (-not (Test-Command $Name)) {
        throw "$Name was not found. $InstallHint"
    }
}

function Ensure-Rust {
    Add-CargoPath
    if (-not (Test-Command "cargo")) {
        if ($SkipDeps) {
            throw "cargo was not found and -SkipDeps was set. Install Rust first, then re-run this script."
        }

        Write-Step "Installing Rust with winget"
        if (-not (Test-Command "winget")) {
            throw "winget was not found. Install Rust from https://rustup.rs/, then re-run this script."
        }

        Invoke-External "winget" @(
            "install",
            "--id",
            "Rustlang.Rustup",
            "--exact",
            "--source",
            "winget",
            "--accept-package-agreements",
            "--accept-source-agreements"
        )
        Refresh-Path
    }

    if (-not $SkipDeps -and (Test-Command "rustup")) {
        Write-Step "Ensuring the stable Rust toolchain, rustfmt, and clippy are installed"
        Invoke-External "rustup" @("default", "stable")
        Invoke-External "rustup" @("component", "add", "rustfmt", "clippy")
        Refresh-Path
    }

    Assert-Command "cargo" "Install Rust from https://rustup.rs/."
}

function Try-Install-ResticWith {
    param(
        [string]$Manager,
        [string[]]$Arguments
    )

    if (-not (Test-Command $Manager)) {
        return $false
    }

    try {
        Write-Step "Installing Restic with $Manager"
        Invoke-External $Manager $Arguments
        Refresh-Path
        return $true
    } catch {
        Write-WarningLine "$Manager could not install Restic: $($_.Exception.Message)"
        return $false
    }
}

function Ensure-Restic {
    Refresh-Path
    if (Test-Command "restic") {
        return
    }

    if ($SkipDeps) {
        throw "restic was not found and -SkipDeps was set. Install Restic first, then re-run this script."
    }

    $installed =
        (Try-Install-ResticWith "winget" @(
            "install",
            "--id",
            "restic.restic",
            "--exact",
            "--source",
            "winget",
            "--accept-package-agreements",
            "--accept-source-agreements"
        )) -or
        (Try-Install-ResticWith "scoop" @("install", "restic")) -or
        (Try-Install-ResticWith "choco" @("install", "restic", "-y"))

    if (-not $installed -and -not $DryRun) {
        throw "Could not install Restic. Install it manually from https://restic.net/, then re-run this script."
    }

    Assert-Command "restic" "Install Restic from https://restic.net/."
}

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Get-ReleaseApiUrl {
    if ($ReleaseVersion -eq "latest") {
        return "https://api.github.com/repos/$GitHubRepository/releases/latest"
    }
    return "https://api.github.com/repos/$GitHubRepository/releases/tags/$ReleaseVersion"
}

function Get-ReleaseAssetTarget {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch ($arch.ToUpperInvariant()) {
        "AMD64" { return "windows-x86_64" }
        "ARM64" { return "windows-aarch64" }
        default {
            throw "Unsupported Windows architecture '$arch'. Expected AMD64 or ARM64."
        }
    }
}

function Invoke-GitHubJson {
    param([string]$Uri)

    if ($DryRun) {
        Write-Host "[dry-run] GET $Uri"
        return $null
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    return Invoke-RestMethod -Uri $Uri -Headers $GitHubHeaders
}

function Download-File {
    param(
        [string]$Uri,
        [string]$OutFile
    )

    if ($DryRun) {
        Write-Host "[dry-run] download $Uri -> $OutFile"
        return
    }

    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -Headers $GitHubHeaders
}

function Get-ReleaseAsset {
    param(
        [object]$Release,
        [string]$AssetName
    )

    $asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $asset) {
        throw "Release '$($Release.tag_name)' does not contain asset '$AssetName'."
    }
    return $asset
}

function Assert-ArchiveChecksum {
    param(
        [string]$ShaPath,
        [string]$ArchivePath,
        [string]$AssetName
    )

    $expected = $null
    foreach ($line in Get-Content -Path $ShaPath) {
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -ge 2 -and $parts[-1].TrimStart("*") -eq $AssetName) {
            $expected = $parts[0].ToUpperInvariant()
            break
        }
    }

    if (-not $expected) {
        throw "SHA256SUMS.txt does not contain '$AssetName'."
    }

    $actual = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToUpperInvariant()
    if ($actual -ne $expected) {
        throw "Checksum mismatch for '$AssetName'. Expected $expected but got $actual."
    }
}

function Install-CliFromRelease {
    $assetTarget = Get-ReleaseAssetTarget
    $apiUrl = Get-ReleaseApiUrl

    if ($DryRun) {
        Write-Step "Would resolve $ReleaseVersion GitHub release from $apiUrl"
        Write-Host "[dry-run] asset pattern: codex-backup-<version>-$assetTarget.zip"
        Write-Host "[dry-run] asset checksum: SHA256SUMS.txt"
        Ensure-InstallBinOnPath
        return
    }

    $release = Invoke-GitHubJson $apiUrl
    $tag = $release.tag_name
    $version = $tag -replace '^v', ''
    $assetName = "codex-backup-$version-$assetTarget.zip"
    $asset = Get-ReleaseAsset -Release $release -AssetName $assetName
    $shaAsset = Get-ReleaseAsset -Release $release -AssetName "SHA256SUMS.txt"

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-backup-install-" + [Guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path $tempRoot $assetName
    $shaPath = Join-Path $tempRoot "SHA256SUMS.txt"
    $extractDir = Join-Path $tempRoot "extract"

    try {
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Write-Step "Downloading codex-backup $tag release asset for $assetTarget"
        Download-File $asset.browser_download_url $archivePath
        Download-File $shaAsset.browser_download_url $shaPath

        Write-Step "Verifying release checksum"
        Assert-ArchiveChecksum -ShaPath $shaPath -ArchivePath $archivePath -AssetName $assetName

        Write-Step "Extracting release archive"
        Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force
        $binary = Get-ChildItem -Path $extractDir -Recurse -Filter "codex-backup.exe" |
            Select-Object -First 1
        if (-not $binary) {
            throw "Archive '$assetName' did not contain codex-backup.exe."
        }

        Ensure-InstallBinOnPath
        $destination = Join-Path (Get-ManagedBinDir) "codex-backup.exe"
        Copy-Item -Path $binary.FullName -Destination $destination -Force
    } finally {
        if ($tempRoot -and
            (Test-Path $tempRoot) -and
            $tempRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }

    Refresh-Path
    Assert-Command "codex-backup" "Make sure $(Get-ManagedBinDir) is on PATH."
}

function Install-CliFromSource {
    $repoRoot = Get-RepoRoot
    Assert-Command "cargo" "Install Rust from https://rustup.rs/."

    Write-Step "Installing codex-backup CLI from source"
    Invoke-External "cargo" @(
        "install",
        "--path",
        $repoRoot,
        "--locked",
        "--force",
        "--bin",
        "codex-backup"
    )
    Refresh-Path
    Assert-Command "codex-backup" "Make sure `$HOME\.cargo\bin is on PATH."
}

function Install-Cli {
    if ($InstallMode -eq "Source") {
        Install-CliFromSource
    } else {
        try {
            Install-CliFromRelease
        } catch {
            throw "Failed to install codex-backup from GitHub Release: $($_.Exception.Message) Re-run with -InstallMode Source to build from source with Rust."
        }
    }

    Write-Step "Verifying codex-backup CLI startup"
    Invoke-External "codex-backup" @("doctor")
}

function Get-DefaultEnvPath {
    $base = if ($env:APPDATA) {
        $env:APPDATA
    } else {
        Join-Path $HOME "AppData\Roaming"
    }
    return Join-Path $base "openai\codex-backup\data\.env"
}

function Read-SecretPlain {
    param([string]$Prompt)

    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Read-Required {
    param(
        [string]$Prompt,
        [switch]$Secret
    )

    while ($true) {
        $value = if ($Secret) {
            Read-SecretPlain $Prompt
        } else {
            Read-Host -Prompt $Prompt
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
        Write-WarningLine "$Prompt is required."
    }
}

function Read-WithDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )

    $value = Read-Host -Prompt "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value.Trim()
}

function Format-EnvLine {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($Value -match "[`r`n]") {
        throw "$Name cannot contain a newline."
    }
    return "$Name=$Value"
}

function Write-EnvFile {
    param([string]$EnvPath)

    if ((Test-Path $EnvPath) -and -not $ForceEnv) {
        Write-Step "Using existing .env at $EnvPath"
        return
    }

    if ($DryRun) {
        Write-Step "Would prompt for R2/Restic settings and write $EnvPath"
        return
    }

    $parent = Split-Path -Parent $EnvPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null

    Write-Step "Creating .env at $EnvPath"
    $repository = Read-Host -Prompt "RESTIC_REPOSITORY (leave blank to build it from R2 fields)"
    $lines = @("# Generated by scripts/install.ps1.")

    if (-not [string]::IsNullOrWhiteSpace($repository)) {
        $lines += Format-EnvLine "RESTIC_REPOSITORY" $repository.Trim()
        $lines += Format-EnvLine "R2_ACCESS_KEY_ID" (Read-Required "R2_ACCESS_KEY_ID")
        $lines += Format-EnvLine "R2_SECRET_ACCESS_KEY" (Read-Required "R2_SECRET_ACCESS_KEY" -Secret)
        $lines += Format-EnvLine "R2_REGION" (Read-WithDefault "R2_REGION" "auto")
    } else {
        $lines += Format-EnvLine "R2_ACCOUNT_ID" (Read-Required "R2_ACCOUNT_ID")
        $lines += Format-EnvLine "R2_BUCKET" (Read-Required "R2_BUCKET")
        $lines += Format-EnvLine "R2_PREFIX" (Read-WithDefault "R2_PREFIX" "codex/history")
        $lines += ""
        $lines += Format-EnvLine "R2_ACCESS_KEY_ID" (Read-Required "R2_ACCESS_KEY_ID")
        $lines += Format-EnvLine "R2_SECRET_ACCESS_KEY" (Read-Required "R2_SECRET_ACCESS_KEY" -Secret)
        $lines += Format-EnvLine "R2_REGION" (Read-WithDefault "R2_REGION" "auto")
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($EnvPath, ($lines -join [Environment]::NewLine) + [Environment]::NewLine, $encoding)
}

function Initialize-Repository {
    param([string]$EnvPath)

    if ($SkipInit) {
        Write-Step "Skipping interactive Restic initialization"
        Write-Host "Run this later: codex-backup init --set-password --env-file `"$EnvPath`""
        return
    }

    Write-EnvFile $EnvPath
    Assert-Command "codex-backup" "Install the CLI first."

    Write-Step "Initializing Restic repository"
    Invoke-External "codex-backup" @("init", "--set-password", "--env-file", $EnvPath)
}

function Run-Doctor {
    param([string]$EnvPath)

    if ($DryRun) {
        Invoke-External "codex-backup" @("doctor", "--env-file", $EnvPath)
        return
    }

    if (Test-Command "codex-backup") {
        Write-Step "Checking installation"
        Invoke-External "codex-backup" @("doctor", "--env-file", $EnvPath)
    }
}

function Install-ScheduleIfRequested {
    param([string]$EnvPath)

    if (-not $InstallSchedule) {
        return
    }

    if (-not $DryRun -and -not (Test-Path $EnvPath)) {
        throw "Cannot install a schedule because $EnvPath does not exist."
    }

    Write-Step "Installing daily backup schedule"
    Invoke-External "codex-backup" @("schedule", "install", "--env-file", $EnvPath, "--time", $ScheduleTime)
}

Add-CargoPath
Add-InstallBinPath

if ($SkipDeps) {
    Write-Step "Skipping dependency installation"
} else {
    if ($InstallMode -eq "Source") {
        Ensure-Rust
    } else {
        Write-Step "Skipping Rust installation because release install mode is selected"
    }
    Ensure-Restic
}

Install-Cli
$envPath = Get-DefaultEnvPath
Initialize-Repository $envPath
Run-Doctor $envPath
Install-ScheduleIfRequested $envPath

Write-Step "codex-backup installation script finished"
