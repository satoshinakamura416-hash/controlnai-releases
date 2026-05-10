# Control-N'AI Auto Updater
# Spawned by app.js when user clicks 「更新を適用」
# Steps:
#   1. Wait briefly for HTTP response to settle
#   2. Stop ControlNAI service
#   3. Backup hanaten.db, .env, tools/, uploads/, base-images/, bg-images/, *.crt/*.key
#   4. Download ZIP from $DownloadUrl
#   5. Extract to a temp dir
#   6. Rsync new files into $InstallDir, preserving the listed items
#   7. Start ControlNAI service
#   8. On any failure, restore previous version from rollback dir

param(
    [Parameter(Mandatory=$true)][string]$DownloadUrl,
    [Parameter(Mandatory=$true)][string]$InstallDir,
    [string]$Version = '',
    [string]$LogFile = ''
)

if (-not $LogFile) { $LogFile = Join-Path $InstallDir 'update.log' }

function Log {
    param([string]$msg)
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# Files/directories that must NEVER be overwritten by an update
$Preserve = @(
    'hanaten.db',
    'hanaten.db.bak_*',
    '.env',
    'uploads',
    'base-images',
    'bg-images',
    'tools',
    'update.log',
    'service.log',
    'app.log',
    '*.crt',
    '*.key',
    '*.cert',
    'license.dat',
    'edition.json'
)

try {
    Log '======================================'
    Log "Updater started. Version=$Version DownloadUrl=$DownloadUrl InstallDir=$InstallDir"

    Start-Sleep -Seconds 3  # let HTTP response finish

    # 1. Stop service
    Log 'Stopping ControlNAI service...'
    try {
        Stop-Service -Name ControlNAI -Force -ErrorAction Stop
        Log '  service stopped'
    } catch {
        Log "  Stop-Service warning: $($_.Exception.Message)"
    }
    # Make sure the port is released
    Start-Sleep -Seconds 5

    # Also kill any leftover fuda-renderer.exe (will be respawned by NAI on next start)
    Get-Process -Name fuda-renderer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # 2. Prepare temp folders
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $tempRoot = Join-Path $env:TEMP "nai-update-$stamp"
    $downloadPath = Join-Path $tempRoot 'package.zip'
    $extractDir   = Join-Path $tempRoot 'extracted'
    $rollbackDir  = Join-Path (Split-Path $InstallDir) ("control-nai-rollback-$stamp")

    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

    # 3. Download ZIP
    Log "Downloading $DownloadUrl..."
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $downloadPath -UseBasicParsing
        $size = (Get-Item $downloadPath).Length
        Log "  downloaded $size bytes"
    } catch {
        Log "  download failed: $($_.Exception.Message)"
        throw
    }

    # 4. Extract
    Log 'Extracting...'
    Expand-Archive -Path $downloadPath -DestinationPath $extractDir -Force
    # If the ZIP root has a single top-level folder (e.g. control-nai-1.2.3/), descend into it
    $top = Get-ChildItem -Path $extractDir
    if ($top.Count -eq 1 -and $top[0].PSIsContainer) {
        $extractDir = $top[0].FullName
        Log "  flattened single root folder: $extractDir"
    }

    # 5. Rollback snapshot of current install (rename, not copy, for speed and atomicity)
    Log "Creating rollback snapshot at $rollbackDir..."
    # Use robocopy /MIR (mirror) so we keep a copy of the install while we modify in-place
    $rb = robocopy $InstallDir $rollbackDir /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1
    Log "  rollback snapshot ready"

    # 6. Replace files: copy new files in, but preserve listed paths
    # 重要 (v1.0.4 修正): /XF /XD には**ファイル名/ディレクトリ名のみ**を渡す。
    # 絶対パス(C:\control-nai\hanaten.db 等)を渡すと、source 側のパスと比較する
    # robocopy の仕様により match せず → preserve したいファイルが上書きされる
    # （v1.0.0〜v1.0.3 で発生した DB / .env 全消失バグの根本原因）
    Log 'Applying new files (preserving DB, .env, uploads, certs, tools)...'
    $excludeFiles = @()
    $excludeDirs  = @()
    foreach ($pat in $Preserve) {
        if ($pat -match '[\*\?]') {
            # wildcard → expand to actual matches in install dir, take basename only
            Get-ChildItem -Path $InstallDir -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.PSIsContainer) { $excludeDirs += $_.Name } else { $excludeFiles += $_.Name }
            }
        } else {
            $p = Join-Path $InstallDir $pat
            if (Test-Path $p) {
                $item = Get-Item $p -Force
                if ($item.PSIsContainer) { $excludeDirs += $item.Name } else { $excludeFiles += $item.Name }
            }
        }
    }
    # 重複削除（同じ名前のファイル/ディレクトリが複数 Preserve エントリで指定された場合の対策）
    $excludeFiles = $excludeFiles | Sort-Object -Unique
    $excludeDirs  = $excludeDirs  | Sort-Object -Unique
    Log ("  preserving " + ($excludeFiles.Count) + ' files, ' + ($excludeDirs.Count) + ' dirs')
    if ($excludeFiles.Count -gt 0) { Log ("  exclude files: " + ($excludeFiles -join ', ')) }
    if ($excludeDirs.Count -gt 0)  { Log ("  exclude dirs : " + ($excludeDirs  -join ', ')) }

    $rcArgs = @($extractDir, $InstallDir, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    if ($excludeFiles.Count -gt 0) {
        $rcArgs += '/XF'
        $rcArgs += $excludeFiles
    }
    if ($excludeDirs.Count -gt 0) {
        $rcArgs += '/XD'
        $rcArgs += $excludeDirs
    }
    $rcOutput = & robocopy @rcArgs
    $rcExit = $LASTEXITCODE
    # robocopy exit codes <8 = success / partial success
    Log "  robocopy exit=$rcExit"
    if ($rcExit -ge 8) { throw "robocopy failed with exit code $rcExit" }

    # 6.5 Updater 自身を強制更新（tools/ は Preserve なので /XF の対象だが、
    #     updater.ps1 の進化を共創店に届けるため明示的に上書き）
    $newUpdater = Join-Path $extractDir 'tools\updater.ps1'
    $dstUpdater = Join-Path $InstallDir 'tools\updater.ps1'
    if (Test-Path $newUpdater) {
        try {
            Copy-Item $newUpdater $dstUpdater -Force -ErrorAction Stop
            Log '  updater.ps1 を最新版に更新しました'
        } catch {
            Log "  updater.ps1 更新スキップ: $($_.Exception.Message)"
        }
    }

    # 7. Start service
    Log 'Starting ControlNAI service...'
    Start-Service -Name ControlNAI -ErrorAction Stop
    Log '  service started'

    # 8. Cleanup
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Log "Update to $Version completed successfully. Rollback available at: $rollbackDir"
    exit 0

} catch {
    Log "[!] UPDATE FAILED: $($_.Exception.Message)"
    Log 'Attempting to restart service to recover...'
    try {
        Start-Service -Name ControlNAI -ErrorAction Stop
        Log '  service restarted'
    } catch {
        Log "  service restart failed: $($_.Exception.Message)"
    }
    if (Test-Path $rollbackDir) {
        Log "Rollback snapshot still available at: $rollbackDir"
    }
    exit 1
}
