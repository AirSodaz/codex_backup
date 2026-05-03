Set-StrictMode -Version Latest

$Script:ManagedDirectories = @(
    "sessions",
    "archived_sessions",
    "memories"
)

$Script:ManagedFiles = @(
    "session_index.jsonl",
    "history.jsonl"
)

$Script:ExcludedPaths = @(
    "auth.json",
    ".sandbox-secrets",
    "cache",
    "tmp",
    ".tmp",
    ".sandbox",
    ".sandbox-bin",
    "plugins\cache",
    "vendor_imports",
    "worktrees"
)

function Get-CodexBackupAppRoot {
    if ($env:APPDATA) {
        return (Join-Path $env:APPDATA "codex-backup")
    }

    return (Join-Path (Join-Path $env:USERPROFILE "AppData\Roaming") "codex-backup")
}

function Get-CodexBackupDefaultCodexDir {
    return (Join-Path $env:USERPROFILE ".codex")
}

function Get-CodexBackupDefaultEnvPath {
    param([string]$RepoRoot)
    return (Join-Path $RepoRoot ".env")
}

function Get-CodexBackupDefaultPasswordFile {
    return (Join-Path (Get-CodexBackupAppRoot) "restic-password.dpapi")
}

function Get-CodexManagedRelativePaths {
    return @($Script:ManagedDirectories + $Script:ManagedFiles)
}

function Get-CodexExcludedRelativePaths {
    return @($Script:ExcludedPaths)
}

function Import-CodexBackupEnv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Environment file not found: $Path"
    }

    $values = [ordered]@{}

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
            continue
        }

        $match = [regex]::Match($line, "^\s*([^#=]+?)\s*=\s*(.*)\s*$")
        if (-not $match.Success) {
            continue
        }

        $name = $match.Groups[1].Value.Trim()
        $value = $match.Groups[2].Value.Trim()

        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            if ($value.Length -ge 2) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $values[$name] = $value
    }

    return $values
}

function Get-CodexEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Env,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$DefaultValue = ""
    )

    if ($Env.Contains($Name) -and -not [string]::IsNullOrWhiteSpace([string]$Env[$Name])) {
        return [string]$Env[$Name]
    }

    return $DefaultValue
}

function Assert-CodexEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Env,
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    $missing = @()
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace((Get-CodexEnvValue -Env $Env -Name $name))) {
            $missing += $name
        }
    }

    if ($missing.Count -gt 0) {
        throw "Missing required .env value(s): $($missing -join ', ')"
    }
}

function Get-CodexResticRepository {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Env
    )

    $explicitRepository = Get-CodexEnvValue -Env $Env -Name "RESTIC_REPOSITORY"
    if (-not [string]::IsNullOrWhiteSpace($explicitRepository)) {
        return $explicitRepository
    }

    Assert-CodexEnvValue -Env $Env -Names @("R2_BUCKET")

    $endpoint = Get-CodexEnvValue -Env $Env -Name "R2_ENDPOINT"
    if ([string]::IsNullOrWhiteSpace($endpoint)) {
        Assert-CodexEnvValue -Env $Env -Names @("R2_ACCOUNT_ID")
        $accountId = Get-CodexEnvValue -Env $Env -Name "R2_ACCOUNT_ID"
        $endpoint = "https://$accountId.r2.cloudflarestorage.com"
    }

    $bucket = Get-CodexEnvValue -Env $Env -Name "R2_BUCKET"
    $prefix = (Get-CodexEnvValue -Env $Env -Name "R2_PREFIX").Trim("/")
    $repository = "s3:$($endpoint.TrimEnd('/'))/$bucket"

    if (-not [string]::IsNullOrWhiteSpace($prefix)) {
        $repository = "$repository/$prefix"
    }

    return $repository
}

function Save-CodexResticPassword {
    param(
        [Parameter(Mandatory = $true)]
        [securestring]$Password,
        [string]$PasswordFile = (Get-CodexBackupDefaultPasswordFile)
    )

    $parent = Split-Path -Parent $PasswordFile
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $Password | ConvertFrom-SecureString | Set-Content -LiteralPath $PasswordFile -Encoding UTF8
    return $PasswordFile
}

function Get-CodexResticPassword {
    param(
        [string]$PasswordFile = (Get-CodexBackupDefaultPasswordFile)
    )

    if (-not (Test-Path -LiteralPath $PasswordFile)) {
        throw "Restic password file not found: $PasswordFile. Run scripts\init-repo.ps1 first."
    }

    $secure = Get-Content -LiteralPath $PasswordFile -Raw | ConvertTo-SecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Set-CodexResticProcessEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Env,
        [string]$PasswordFile = (Get-CodexBackupDefaultPasswordFile)
    )

    Assert-CodexEnvValue -Env $Env -Names @("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY")

    $repository = Get-CodexResticRepository -Env $Env
    $env:RESTIC_REPOSITORY = $repository
    $env:AWS_ACCESS_KEY_ID = Get-CodexEnvValue -Env $Env -Name "R2_ACCESS_KEY_ID"
    $env:AWS_SECRET_ACCESS_KEY = Get-CodexEnvValue -Env $Env -Name "R2_SECRET_ACCESS_KEY"
    $env:AWS_DEFAULT_REGION = Get-CodexEnvValue -Env $Env -Name "R2_REGION" -DefaultValue "auto"
    $env:RESTIC_PASSWORD = Get-CodexResticPassword -PasswordFile $PasswordFile

    return [pscustomobject]@{
        Repository = $repository
        Region = $env:AWS_DEFAULT_REGION
        PasswordFile = $PasswordFile
    }
}

function Write-CodexBackupLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$LogPath,
        [string]$Level = "INFO"
    )

    $line = "{0} [{1}] {2}" -f (Get-Date).ToString("s"), $Level, $Message
    Write-Host $line

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $parent = Split-Path -Parent $LogPath
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
}

function Invoke-CodexNativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,
        [string]$LogPath
    )

    Write-CodexBackupLog -Message ("Running: {0} {1}" -f $FilePath, ($ArgumentList -join " ")) -LogPath $LogPath
    $output = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE

    foreach ($line in @($output)) {
        Write-CodexBackupLog -Message ([string]$line) -LogPath $LogPath
    }

    if ($exitCode -ne 0) {
        throw "$FilePath exited with code $exitCode."
    }

    return $output
}

function Copy-CodexManagedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        return $false
    }

    $destinationPath = Join-Path $DestinationRoot $RelativePath
    $destinationParent = Split-Path -Parent $destinationPath
    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }

    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
    return $true
}

function Invoke-CodexSqliteBackup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [string]$SqliteExe = "sqlite3"
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "SQLite source not found: $SourcePath"
    }

    $destinationParent = Split-Path -Parent $DestinationPath
    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }

    $resolvedSource = (Resolve-Path -LiteralPath $SourcePath).Path
    $backupCommand = ".backup `"$DestinationPath`""
    $output = & $SqliteExe $resolvedSource $backupCommand 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "sqlite3 .backup failed for '$SourcePath' with exit code $exitCode. $output"
    }
}

function New-CodexBackupStaging {
    param(
        [string]$CodexDir = (Get-CodexBackupDefaultCodexDir),
        [string]$WorkRoot = (Join-Path (Get-CodexBackupAppRoot) "staging"),
        [string]$SqliteExe = "sqlite3",
        [string]$Timestamp = (Get-Date -Format "yyyyMMdd-HHmmss")
    )

    if (-not (Test-Path -LiteralPath $CodexDir)) {
        throw "Codex directory not found: $CodexDir"
    }

    if (-not (Test-Path -LiteralPath $WorkRoot)) {
        New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    }

    $stagingDir = Join-Path $WorkRoot "codex-backup-$Timestamp"
    if (Test-Path -LiteralPath $stagingDir) {
        throw "Staging directory already exists: $stagingDir"
    }

    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

    $included = @()
    foreach ($relativePath in Get-CodexManagedRelativePaths) {
        if (Copy-CodexManagedPath -SourceRoot $CodexDir -DestinationRoot $stagingDir -RelativePath $relativePath) {
            $included += $relativePath
        }
    }

    $sqliteBackups = @()
    $sqliteDir = Join-Path $stagingDir "sqlite"
    $sqliteFiles = Get-ChildItem -LiteralPath $CodexDir -File -Filter "*.sqlite" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "logs_*.sqlite" -or $_.Name -like "state_*.sqlite" }

    foreach ($sqliteFile in $sqliteFiles) {
        $destination = Join-Path $sqliteDir $sqliteFile.Name
        Invoke-CodexSqliteBackup -SourcePath $sqliteFile.FullName -DestinationPath $destination -SqliteExe $SqliteExe
        $sqliteBackups += [pscustomobject]@{
            sourceFile = $sqliteFile.Name
            backupFile = ("sqlite/{0}" -f $sqliteFile.Name)
            sourceLastWriteTime = $sqliteFile.LastWriteTimeUtc.ToString("o")
            sizeBytes = (Get-Item -LiteralPath $destination).Length
        }
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        backupName = "codex-history"
        createdAt = (Get-Date).ToUniversalTime().ToString("o")
        host = $env:COMPUTERNAME
        user = $env:USERNAME
        codexDir = (Resolve-Path -LiteralPath $CodexDir).Path
        includedPaths = @($included)
        excludedPaths = @(Get-CodexExcludedRelativePaths)
        sqliteBackups = @($sqliteBackups)
        restoreNotes = @(
            "Close Codex before applying restored files.",
            "auth.json and .sandbox-secrets are intentionally excluded.",
            "SQLite files are restored from online .backup snapshots; stale WAL/SHM files are moved aside during apply."
        )
    }

    $manifestPath = Join-Path $stagingDir "manifest.json"
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    return [pscustomobject]@{
        StagingDir = $stagingDir
        ManifestPath = $manifestPath
        IncludedPaths = @($included)
        SqliteBackups = @($sqliteBackups)
    }
}

function Find-CodexRestoredStaging {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RestoreRoot
    )

    $manifests = Get-ChildItem -LiteralPath $RestoreRoot -Recurse -File -Filter "manifest.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($manifestFile in $manifests) {
        try {
            $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
            if ($manifest.backupName -eq "codex-history" -and $manifest.schemaVersion -eq 1) {
                return (Split-Path -Parent $manifestFile.FullName)
            }
        }
        catch {
            continue
        }
    }

    throw "No codex-history manifest found under: $RestoreRoot"
}

function Test-CodexProcessStopped {
    param(
        [string[]]$ProcessNames = @("Codex", "codex")
    )

    $running = @()
    foreach ($name in $ProcessNames) {
        $running += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }

    if ($running.Count -gt 0) {
        $names = ($running | Select-Object -ExpandProperty ProcessName -Unique) -join ", "
        throw "Codex appears to be running ($names). Close Codex before applying a restore."
    }
}

function Move-CodexExistingPathToRollback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$CodexDir,
        [Parameter(Mandatory = $true)]
        [string]$RollbackDir
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $relative = $Path.Substring($CodexDir.TrimEnd("\").Length).TrimStart("\")
    $destination = Join-Path $RollbackDir $relative
    $destinationParent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }

    Move-Item -LiteralPath $Path -Destination $destination -Force
}

function Invoke-CodexRestoreApply {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RestoredStagingDir,
        [string]$CodexDir = (Get-CodexBackupDefaultCodexDir),
        [string]$RollbackRoot = (Join-Path (Get-CodexBackupAppRoot) "rollback")
    )

    $manifestPath = Join-Path $RestoredStagingDir "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.backupName -ne "codex-history" -or $manifest.schemaVersion -ne 1) {
        throw "Unsupported restore manifest: $manifestPath"
    }

    Test-CodexProcessStopped

    if (-not (Test-Path -LiteralPath $CodexDir)) {
        New-Item -ItemType Directory -Path $CodexDir -Force | Out-Null
    }

    $rollbackDir = Join-Path $RollbackRoot ("codex-before-restore-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $rollbackDir -Force | Out-Null

    foreach ($relativePath in @($manifest.includedPaths)) {
        $source = Join-Path $RestoredStagingDir $relativePath
        if (-not (Test-Path -LiteralPath $source)) {
            continue
        }

        $destination = Join-Path $CodexDir $relativePath
        Move-CodexExistingPathToRollback -Path $destination -CodexDir $CodexDir -RollbackDir $rollbackDir

        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
    }

    foreach ($sqliteBackup in @($manifest.sqliteBackups)) {
        $backupFile = [string]$sqliteBackup.backupFile
        $sourceFile = [string]$sqliteBackup.sourceFile
        $source = Join-Path $RestoredStagingDir ($backupFile -replace "/", "\")
        if (-not (Test-Path -LiteralPath $source)) {
            throw "SQLite backup missing from restored snapshot: $backupFile"
        }

        $destination = Join-Path $CodexDir $sourceFile
        Move-CodexExistingPathToRollback -Path $destination -CodexDir $CodexDir -RollbackDir $rollbackDir
        Move-CodexExistingPathToRollback -Path "$destination-wal" -CodexDir $CodexDir -RollbackDir $rollbackDir
        Move-CodexExistingPathToRollback -Path "$destination-shm" -CodexDir $CodexDir -RollbackDir $rollbackDir
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    return [pscustomobject]@{
        CodexDir = $CodexDir
        RollbackDir = $rollbackDir
    }
}

Export-ModuleMember -Function @(
    "Assert-CodexEnvValue",
    "Find-CodexRestoredStaging",
    "Get-CodexBackupAppRoot",
    "Get-CodexBackupDefaultCodexDir",
    "Get-CodexBackupDefaultEnvPath",
    "Get-CodexBackupDefaultPasswordFile",
    "Get-CodexExcludedRelativePaths",
    "Get-CodexManagedRelativePaths",
    "Get-CodexResticPassword",
    "Get-CodexResticRepository",
    "Import-CodexBackupEnv",
    "Invoke-CodexNativeCommand",
    "Invoke-CodexRestoreApply",
    "Invoke-CodexSqliteBackup",
    "New-CodexBackupStaging",
    "Save-CodexResticPassword",
    "Set-CodexResticProcessEnvironment",
    "Test-CodexProcessStopped",
    "Write-CodexBackupLog"
)
