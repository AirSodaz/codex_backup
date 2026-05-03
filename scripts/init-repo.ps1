[CmdletBinding()]
param(
    [string]$EnvFile,
    [string]$PasswordFile,
    [switch]$SetPassword
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

if ($SetPassword -or -not (Test-Path -LiteralPath $PasswordFile)) {
    $password = Read-Host "Restic repository password" -AsSecureString
    Save-CodexResticPassword -Password $password -PasswordFile $PasswordFile | Out-Null
    Write-Host "Saved encrypted Restic password to $PasswordFile"
}

$config = Import-CodexBackupEnv -Path $EnvFile
$restic = Set-CodexResticProcessEnvironment -Env $config -PasswordFile $PasswordFile
Write-Host "Restic repository: $($restic.Repository)"

$snapshots = & restic snapshots 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "Restic repository is already initialized."
    $snapshots
    exit 0
}

Write-Host "Repository check did not succeed; attempting restic init."
& restic init
if ($LASTEXITCODE -ne 0) {
    throw "restic init failed."
}

Write-Host "Restic repository initialized."
