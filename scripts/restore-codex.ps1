[CmdletBinding()]
param(
    [string]$Snapshot = "latest",
    [string]$EnvFile,
    [string]$PasswordFile,
    [string]$TargetRoot,
    [string]$CodexDir,
    [string]$RollbackRoot,
    [switch]$Apply
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
if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
    $TargetRoot = Join-Path (Get-CodexBackupAppRoot) "restore"
}
if ([string]::IsNullOrWhiteSpace($CodexDir)) {
    $CodexDir = Get-CodexBackupDefaultCodexDir
}
if ([string]::IsNullOrWhiteSpace($RollbackRoot)) {
    $RollbackRoot = Join-Path (Get-CodexBackupAppRoot) "rollback"
}

$restoreRunRoot = Join-Path $TargetRoot ("restore-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Path $restoreRunRoot -Force | Out-Null

$config = Import-CodexBackupEnv -Path $EnvFile
Set-CodexResticProcessEnvironment -Env $config -PasswordFile $PasswordFile | Out-Null

Invoke-CodexNativeCommand -FilePath "restic" -ArgumentList @(
    "restore",
    $Snapshot,
    "--target",
    $restoreRunRoot
) | Out-Null

$restoredStaging = Find-CodexRestoredStaging -RestoreRoot $restoreRunRoot
Write-Host "Restored snapshot staging: $restoredStaging"

if (-not $Apply) {
    Write-Host "Restore completed to a temporary directory only. Re-run with -Apply after closing Codex to update $CodexDir."
    exit 0
}

$result = Invoke-CodexRestoreApply -RestoredStagingDir $restoredStaging -CodexDir $CodexDir -RollbackRoot $RollbackRoot
Write-Host "Applied restore to $($result.CodexDir)"
Write-Host "Previous managed files were moved to $($result.RollbackDir)"
