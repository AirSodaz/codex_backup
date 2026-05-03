[CmdletBinding()]
param(
    [string]$CodexDir,
    [string]$EnvFile,
    [string]$PasswordFile,
    [string]$WorkRoot,
    [string]$LogRoot,
    [string]$SqliteExe = "sqlite3",
    [switch]$SkipRestic,
    [switch]$KeepStaging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $RepoRoot "lib\CodexBackup.psm1") -Force

if ([string]::IsNullOrWhiteSpace($CodexDir)) {
    $CodexDir = Get-CodexBackupDefaultCodexDir
}
if ([string]::IsNullOrWhiteSpace($EnvFile)) {
    $EnvFile = Get-CodexBackupDefaultEnvPath -RepoRoot $RepoRoot
}
if ([string]::IsNullOrWhiteSpace($PasswordFile)) {
    $PasswordFile = Get-CodexBackupDefaultPasswordFile
}
if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = Join-Path (Get-CodexBackupAppRoot) "staging"
}
if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    $LogRoot = Join-Path (Get-CodexBackupAppRoot) "logs"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $LogRoot "backup-$timestamp.log"
$staging = $null

try {
    Write-CodexBackupLog -Message "Creating Codex backup staging from $CodexDir" -LogPath $logPath
    $staging = New-CodexBackupStaging -CodexDir $CodexDir -WorkRoot $WorkRoot -SqliteExe $SqliteExe -Timestamp $timestamp
    Write-CodexBackupLog -Message "Staging ready: $($staging.StagingDir)" -LogPath $logPath

    if ($SkipRestic) {
        Write-CodexBackupLog -Message "SkipRestic was set; leaving staged backup for inspection." -LogPath $logPath
        Write-Host $staging.StagingDir
        exit 0
    }

    $config = Import-CodexBackupEnv -Path $EnvFile
    Set-CodexResticProcessEnvironment -Env $config -PasswordFile $PasswordFile | Out-Null

    Invoke-CodexNativeCommand -FilePath "restic" -ArgumentList @(
        "backup",
        $staging.StagingDir,
        "--tag",
        "codex",
        "--tag",
        "windows"
    ) -LogPath $logPath | Out-Null

    Invoke-CodexNativeCommand -FilePath "restic" -ArgumentList @(
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
    ) -LogPath $logPath | Out-Null

    Write-CodexBackupLog -Message "Backup complete." -LogPath $logPath
}
finally {
    if ($staging -and -not $KeepStaging -and -not $SkipRestic) {
        if (Test-Path -LiteralPath $staging.StagingDir) {
            Remove-Item -LiteralPath $staging.StagingDir -Recurse -Force
        }
    }
}
