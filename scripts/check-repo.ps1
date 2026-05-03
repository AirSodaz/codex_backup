[CmdletBinding()]
param(
    [string]$EnvFile,
    [string]$PasswordFile,
    [switch]$SkipPrune
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $RepoRoot "lib\CodexBackup.psm1") -Force

if ([string]::IsNullOrWhiteSpace($EnvFile)) {
    $EnvFile = Get-CodexBackupDefaultEnvPath -RepoRoot $RepoRoot
}
if ([string]::IsNullOrWhiteSpace($PasswordFile)) {
    $PasswordFile = Get-CodexBackupDefaultPasswordFile
}

$config = Import-CodexBackupEnv -Path $EnvFile
Set-CodexResticProcessEnvironment -Env $config -PasswordFile $PasswordFile | Out-Null

Invoke-CodexNativeCommand -FilePath "restic" -ArgumentList @("snapshots", "--tag", "codex") | Out-Null
Invoke-CodexNativeCommand -FilePath "restic" -ArgumentList @("check") | Out-Null

if (-not $SkipPrune) {
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
    ) | Out-Null
}

Write-Host "Repository check complete."
