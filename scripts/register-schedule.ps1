[CmdletBinding()]
param(
    [string]$TaskName = "Codex R2 History Backup",
    [string]$At = "03:00",
    [string]$BackupScript,
    [string]$EnvFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BackupScript)) {
    $BackupScript = Join-Path $PSScriptRoot "backup-codex.ps1"
}
if ([string]::IsNullOrWhiteSpace($EnvFile)) {
    $EnvFile = Join-Path $RepoRoot ".env"
}

$powerShell = (Get-Command powershell.exe).Source
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$BackupScript`" -EnvFile `"$EnvFile`""
$action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($At, "HH:mm", $null))
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel LeastPrivilege

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Description "Back up Codex history and SQLite snapshots to Cloudflare R2 with Restic." -Force | Out-Null
Write-Host "Registered scheduled task '$TaskName' at $At."
