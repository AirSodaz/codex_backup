Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ModulePath = Join-Path $RepoRoot "lib\CodexBackup.psm1"

Import-Module $ModulePath -Force

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-PathExists {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path) "Expected path to exist: $Path"
}

function Assert-PathMissing {
    param([string]$Path)
    Assert-True (-not (Test-Path -LiteralPath $Path)) "Expected path to be absent: $Path"
}

function New-TestDirectory {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-backup-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Invoke-Test {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    try {
        & $Body
        Write-Host "[PASS] $Name"
    }
    catch {
        Write-Host "[FAIL] $Name"
        Write-Host $_
        throw
    }
}

Invoke-Test "Import-CodexBackupEnv parses quoted values and comments" {
    $tmp = New-TestDirectory
    try {
        $envPath = Join-Path $tmp ".env"
        @(
            "# comment",
            "R2_ACCOUNT_ID = abc123",
            "R2_BUCKET=codex-history",
            "R2_PREFIX=""codex/backups""",
            "R2_ACCESS_KEY_ID='access-key'",
            "R2_SECRET_ACCESS_KEY = secret-value"
        ) | Set-Content -LiteralPath $envPath -Encoding UTF8

        $env = Import-CodexBackupEnv -Path $envPath

        Assert-Equal $env.R2_ACCOUNT_ID "abc123" "Account id should parse."
        Assert-Equal $env.R2_BUCKET "codex-history" "Bucket should parse."
        Assert-Equal $env.R2_PREFIX "codex/backups" "Quoted prefix should parse."
        Assert-Equal $env.R2_ACCESS_KEY_ID "access-key" "Single-quoted key should parse."
        Assert-Equal $env.R2_SECRET_ACCESS_KEY "secret-value" "Secret should parse."
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
}

Invoke-Test "Get-CodexResticRepository builds a Cloudflare R2 S3 repository URL" {
    $env = @{
        R2_ACCOUNT_ID = "abc123"
        R2_BUCKET = "codex-history"
        R2_PREFIX = "codex/backups/"
    }

    $repository = Get-CodexResticRepository -Env $env

    Assert-Equal $repository "s3:https://abc123.r2.cloudflarestorage.com/codex-history/codex/backups" "Repository URL should match R2 S3 format."
}

Invoke-Test "Parsed .env values can be used to build the Restic repository" {
    $tmp = New-TestDirectory
    try {
        $envPath = Join-Path $tmp ".env"
        @(
            "R2_ACCOUNT_ID=abc123",
            "R2_BUCKET=codex-history",
            "R2_PREFIX=codex/backups",
            "R2_ACCESS_KEY_ID=access-key",
            "R2_SECRET_ACCESS_KEY=secret-value"
        ) | Set-Content -LiteralPath $envPath -Encoding UTF8

        $env = Import-CodexBackupEnv -Path $envPath
        $repository = Get-CodexResticRepository -Env $env

        Assert-Equal $repository "s3:https://abc123.r2.cloudflarestorage.com/codex-history/codex/backups" "Repository URL should work with parsed .env values."
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
}

Invoke-Test "New-CodexBackupStaging copies managed history and excludes secrets" {
    $tmp = New-TestDirectory
    try {
        $source = Join-Path $tmp "source"
        $workRoot = Join-Path $tmp "work"
        New-Item -ItemType Directory -Path $source | Out-Null

        New-Item -ItemType Directory -Path (Join-Path $source "sessions\2026\05") -Force | Out-Null
        "session" | Set-Content -LiteralPath (Join-Path $source "sessions\2026\05\rollout.jsonl") -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $source "archived_sessions") -Force | Out-Null
        "archived" | Set-Content -LiteralPath (Join-Path $source "archived_sessions\old.jsonl") -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $source "memories") -Force | Out-Null
        "memory" | Set-Content -LiteralPath (Join-Path $source "memories\MEMORY.md") -Encoding UTF8
        "index" | Set-Content -LiteralPath (Join-Path $source "session_index.jsonl") -Encoding UTF8
        "history" | Set-Content -LiteralPath (Join-Path $source "history.jsonl") -Encoding UTF8

        "secret" | Set-Content -LiteralPath (Join-Path $source "auth.json") -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $source ".sandbox-secrets") -Force | Out-Null
        "secret" | Set-Content -LiteralPath (Join-Path $source ".sandbox-secrets\secret.txt") -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $source "cache") -Force | Out-Null
        "cache" | Set-Content -LiteralPath (Join-Path $source "cache\blob.bin") -Encoding UTF8

        & sqlite3 (Join-Path $source "state_5.sqlite") "CREATE TABLE state(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO state(value) VALUES('ok');"
        & sqlite3 (Join-Path $source "logs_2.sqlite") "CREATE TABLE logs(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO logs(value) VALUES('ok');"

        $result = New-CodexBackupStaging -CodexDir $source -WorkRoot $workRoot -SqliteExe "sqlite3" -Timestamp "20260504-010203"

        Assert-PathExists (Join-Path $result.StagingDir "sessions\2026\05\rollout.jsonl")
        Assert-PathExists (Join-Path $result.StagingDir "archived_sessions\old.jsonl")
        Assert-PathExists (Join-Path $result.StagingDir "memories\MEMORY.md")
        Assert-PathExists (Join-Path $result.StagingDir "session_index.jsonl")
        Assert-PathExists (Join-Path $result.StagingDir "history.jsonl")
        Assert-PathExists (Join-Path $result.StagingDir "sqlite\state_5.sqlite")
        Assert-PathExists (Join-Path $result.StagingDir "sqlite\logs_2.sqlite")
        Assert-PathExists $result.ManifestPath

        Assert-PathMissing (Join-Path $result.StagingDir "auth.json")
        Assert-PathMissing (Join-Path $result.StagingDir ".sandbox-secrets")
        Assert-PathMissing (Join-Path $result.StagingDir "cache")

        $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json
        Assert-True (@($manifest.includedPaths) -contains "sessions") "Manifest should include sessions."
        Assert-True (@($manifest.includedPaths) -contains "memories") "Manifest should include memories."
        Assert-True (@($manifest.excludedPaths) -contains "auth.json") "Manifest should record auth.json exclusion."
        Assert-True (@($manifest.excludedPaths) -contains ".sandbox-secrets") "Manifest should record sandbox secret exclusion."
        Assert-Equal @($manifest.sqliteBackups).Count 2 "Manifest should record two SQLite backups."
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
}

Write-Host "All tests passed."
