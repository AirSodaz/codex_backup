[CmdletBinding()]
param(
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Tool {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

$missing = @()
foreach ($tool in @("sqlite3", "restic")) {
    if (Test-Tool $tool) {
        Write-Host "$tool is available."
    }
    else {
        Write-Host "$tool is missing."
        $missing += $tool
    }
}

if ($missing.Count -eq 0) {
    Write-Host "All required tools are available."
    exit 0
}

if ($CheckOnly) {
    throw "Missing required tool(s): $($missing -join ', ')"
}

if (-not (Test-Tool "scoop")) {
    throw "Scoop is required to install missing tools automatically. Install Scoop or install manually: $($missing -join ', ')"
}

foreach ($tool in $missing) {
    if ($tool -eq "sqlite3") {
        scoop install sqlite
    }
    elseif ($tool -eq "restic") {
        scoop install restic
    }
}

foreach ($tool in @("sqlite3", "restic")) {
    if (-not (Test-Tool $tool)) {
        throw "$tool is still unavailable after installation."
    }
}

Write-Host "Tool installation complete."
