<#
.SYNOPSIS
    Move-Media-Nas - relocate a media tree to a NAS, safely alongside a running Optimize-Media job.
.DESCRIPTION
    Works in three phases:
      A) while Optimize-Media.ps1 is still running, move only files that are
         already settled: videos already re-encoded to the run's target codec
         (av1) plus non-media files (the run never touches them). Files the
         run still owns are left alone.
      B) watch until the run becomes inactive (no ffmpeg child, temp/ drained).
      C) final move of everything that remains, whatever its state.
    Every move is copy -> size verify -> (decode check for videos) -> rename
    into place -> delete source, so a failed copy never loses the original.
    Files already at the destination with the same size (and, for videos, a
    valid container) are treated as done and the source is removed; a size
    conflict is reported and left untouched. Idempotent: safe to re-run.
    The run is detected by its ffmpeg children and the temp/ folder it fills
    while encoding - not by command line, because the console wrapper does not
    expose the script name.
.EXAMPLE
    .\Move-Media-Nas.ps1
.PARAMETER Source
    Root folder whose contents are moved (default E:\Fshare\Anime).
.PARAMETER Dest
    Destination path (default \\192.168.50.103\Storage\Storage\Anime).
.PARAMETER Workers
    Parallel copy streams (default 3).
.PARAMETER CopyAll
    Skip phase A and do the final move immediately. Use only when no
    Optimize-Media run is active; if a run IS active this flag is ignored
    (moving in-flight sources would break the encode).
#>
[CmdletBinding()]
param(
    [string]$Source = 'E:\Fshare\Anime',
    [string]$Dest = '\\192.168.50.103\Storage\Storage\Anime',
    [int]$Workers = 3,
    [switch]$CopyAll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$rootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$tempDir = Join-Path $rootDir 'temp'
$logDir = Join-Path $rootDir 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("move-anime-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

if (-not (Test-Path -LiteralPath $Source)) { Write-Host "Source not found: $Source" -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $Dest)) {
    Write-Host "Destination not reachable: $Dest" -ForegroundColor Red
    Write-Host "Check the share, credentials and network/VPN state." -ForegroundColor Red
    exit 1
}

$cfg = Get-Content (Join-Path $rootDir 'config.json') -Raw | ConvertFrom-Json
$FFMPEG = [string]$cfg.tools.ffmpeg
$FFPROBE = [string]$cfg.tools.ffprobe
$imgExt = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.heif')
$vidExt = @('.mp4', '.mov', '.mkv', '.avi', '.m4v', '.wmv', '.flv', '.webm', '.ts', '.mts', '.m2ts', '.mpg', '.mpeg', '.3gp')

function Write-Log([string]$msg) { Add-Content -LiteralPath $logFile -Value $msg }

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N1} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}
function Format-Duration([double]$sec) {
    $t = [TimeSpan]::FromSeconds([math]::Round([math]::Max(0, $sec)))
    if ($t.TotalHours -ge 1) { return $t.ToString('h\h\ mm\m') }
    return $t.ToString('m\m\ ss\s')
}

function Get-VideoCodec([string]$file) {
    try {
        return [string](& $FFPROBE -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 $file 2>$null | Select-Object -First 1)
    } catch { return '' }
}

function Get-RunActive {
    if (@(Get-Process -Name ffmpeg -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    return (@(Get-ChildItem -LiteralPath $tempDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(vid_|img_)' }).Count -gt 0)
}

# copy -> verify size -> decode check (videos) -> rename into place -> delete source
$stats = @{ ok = 0; exists = 0; conflict = 0; fail = 0; kept = 0 }
function Add-Result($r) {
    switch ($r.Status) {
        'ok'      { $script:stats.ok++ }
        'exists'  { $script:stats.exists++ }
        'conflict' { $script:stats.conflict++ }
        'exists-kept' { $script:stats.kept++ }
        default   { $script:stats.fail++ }
    }
    Write-Log ("{0} | {1}{2}" -f $r.Status.ToUpper(), $r.File, $(if ($r.Detail) { " | $($r.Detail)" } else { '' }))
}

function Remove-PruneEmpty([string]$root) {
    $dirs = @(Get-ChildItem -LiteralPath $root -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending)
    $removed = 0
    foreach ($d in $dirs) {
        if (@(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            try { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop; $removed++ } catch { }
        }
    }
    if ($removed -gt 0) { Write-Host "  removed $removed empty folder(s)" -ForegroundColor Green }
    return $removed
}

function Invoke-MoveBatch([string[]]$paths) {
    if ($paths.Count -eq 0) { return }
    $total = $paths.Count
    $script:batchBytes = ($paths | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum
    Write-Host "  batch: $total files, $(Format-Size $script:batchBytes) bytes" -ForegroundColor Cyan
    $swb = [System.Diagnostics.Stopwatch]::StartNew()
    $done = 0; $okBytes = 0; $failN = 0; $lastProg = -1
    $paths | ForEach-Object -Parallel {
        $src = $_
        $destRoot = $using:Dest
        $sourceRoot = $using:Source
        $ffprobe = $using:FFPROBE
        $vidExt = $using:vidExt
        $rel = $src.Substring($sourceRoot.Length).TrimStart('\', '/')
        $dest = Join-Path $destRoot $rel
        $fileName = Split-Path $dest -Leaf
        $folder = Split-Path $dest -Parent
        $isVideo = ($vidExt -contains [System.IO.Path]::GetExtension($src).ToLower())
        $srcLen = try { (Get-Item -LiteralPath $src).Length } catch { 0 }

        if (Test-Path -LiteralPath $dest) {
            try {
                $dLen = (Get-Item -LiteralPath $dest).Length
                $sLen = (Get-Item -LiteralPath $src).Length
            } catch { return [pscustomobject]@{ File = $rel; Status = 'fail-io'; Detail = $_.Exception.Message; Size = $srcLen } }
            if ($dLen -eq $sLen) {
                if ($isVideo) {
                    & $ffprobe -v error -show_entries format=duration -of csv=p=0 $dest 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        return [pscustomobject]@{ File = $rel; Status = 'conflict'; Detail = 'existing dest copy fails to open'; Size = $sLen }
                    }
                }
                try { Remove-Item -LiteralPath $src -Force }
                catch { return [pscustomobject]@{ File = $rel; Status = 'exists-kept'; Detail = 'source delete failed'; Size = $sLen } }
                return [pscustomobject]@{ File = $rel; Status = 'exists'; Detail = ''; Size = $sLen }
            }
            return [pscustomobject]@{ File = $rel; Status = 'conflict'; Detail = "dest size $dLen vs source $sLen"; Size = $sLen }
        }

        try { New-Item -ItemType Directory -Path $folder -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
        $tmpDest = Join-Path $folder ($fileName + ".move-" + [guid]::NewGuid().ToString('N'))
        try {
            Copy-Item -LiteralPath $src -Destination $tmpDest -Force
            $ok = (Get-Item -LiteralPath $tmpDest).Length -eq (Get-Item -LiteralPath $src).Length
            if ($ok -and $isVideo) {
                # header-level check: full decode over SMB is far too slow
                & $ffprobe -v error -show_entries format=duration -of csv=p=0 $tmpDest 2>$null | Out-Null
                $ok = ($LASTEXITCODE -eq 0)
            }
            if (-not $ok) {
                Remove-Item -LiteralPath $tmpDest -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{ File = $rel; Status = 'fail-copy'; Detail = 'copy verify failed'; Size = $srcLen }
            }
            Move-Item -LiteralPath $tmpDest -Destination $dest -Force
            try {
                $f = Get-Item -LiteralPath $dest
                [System.IO.File]::SetLastWriteTimeUtc($f.FullName, (Get-Item -LiteralPath $src).LastWriteTimeUtc)
            } catch { }
            Remove-Item -LiteralPath $src -Force
            return [pscustomobject]@{ File = $rel; Status = 'ok'; Detail = ''; Size = $srcLen }
        } catch {
            Remove-Item -LiteralPath $tmpDest -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ File = $rel; Status = 'fail-copy'; Detail = $_.Exception.Message; Size = $srcLen }
        }
    } -ThrottleLimit $Workers | ForEach-Object {
        $r = $_
        $done++
        Add-Result $r
        if ($r.Status -eq 'ok') { $okBytes += [double]$r.Size } elseif ($r.Status -notin @('exists', 'conflict', 'exists-kept')) { $failN++ }
        if (($done - $lastProg) -ge 25) {
            $lastProg = $done
            $etaS = if ($done -gt 0 -and $script:batchBytes -gt 0) {
                ($swb.Elapsed.TotalSeconds / ([double]$okBytes + 1)) * [math]::Max(0, $script:batchBytes - $okBytes)
            } else { 0 }
            Write-Host ("  [{0}] moved {1}/{2} ({3:N0}%) | {4}/{5} | ETA {6}" -f
                (Get-Date -Format 'HH:mm:ss'), ($script:stats.ok + $script:stats.exists), $total,
                (($script:stats.ok + $script:stats.exists) / $total * 100), (Format-Size $okBytes), (Format-Size $script:batchBytes),
                (Format-Duration $etaS))
        }
    }
}

Write-Host "==================================================" -ForegroundColor Magenta
Write-Host "  Move-Media-Nas" -ForegroundColor Magenta
Write-Host "  Source : $Source"
Write-Host "  Dest   : $Dest"
Write-Host "==================================================" -ForegroundColor Magenta
Write-Log "start: $Source -> $Dest"

# clean stale .move-* temp files left by a crashed/stopped mover, but only when
# no OTHER Move-Media-Nas run is alive (in-flight copies must never be touched)
try {
    $others = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match 'Move-Media-Nas\.ps1' })
    if ($others.Count -eq 0) {
        $stale = @(Get-ChildItem -LiteralPath $Dest -Recurse -File -Filter '*.move-*' -ErrorAction SilentlyContinue)
        if ($stale.Count -gt 0) {
            $stale | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Host "  removed $($stale.Count) stale .move-* temp file(s) from destination" -ForegroundColor Yellow
        }
    }
} catch { }

$runActive = Get-RunActive
if ($runActive -and -not $CopyAll) {
    Write-Host "[Phase A] run active - moving settled files only (processed av1 videos + non-media)" -ForegroundColor Cyan
    $all = @(Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction SilentlyContinue)
    Write-Host "  scanning $($all.Count) files for processed videos... (probe, read-only)"
    $settled = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($f in $all) {
        $ext = $f.Extension.ToLower()
        if ($vidExt -contains $ext) {
            if ((Get-VideoCodec $f.FullName) -eq 'av1') { $settled.Add($f.FullName) }
        } elseif (-not ($imgExt -contains $ext)) {
            $settled.Add($f.FullName)
        }
        $i++
        if (($i % 100) -eq 0) { Write-Host "  probed $i/$($all.Count)..." }
    }
    Write-Host "  moving $($settled.Count) settled files..." -ForegroundColor Cyan
    Invoke-MoveBatch $settled.ToArray()
    Remove-PruneEmpty $Source | Out-Null

    Write-Host "[Phase B] watching until the run finishes..." -ForegroundColor Cyan
    $watchSw = [System.Diagnostics.Stopwatch]::StartNew()
    while (Get-RunActive) {
        Start-Sleep -Seconds 15
        if ($watchSw.Elapsed.TotalMinutes -ge 5) {
            Write-Host "  still waiting - run active (elapsed $([int]$watchSw.Elapsed.TotalMinutes) min)..."
            $watchSw.Restart()
        }
    }
    Start-Sleep -Seconds 30
    Write-Host "[Phase B] run finished, temp drained." -ForegroundColor Green
} else {
    if ($runActive) { Write-Host "Run is active but -CopyAll was requested: moving settled files only to protect the run." -ForegroundColor Yellow }
}

Write-Host "[Phase C] final move of everything remaining..." -ForegroundColor Cyan
$remaining = @(Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction SilentlyContinue)
Write-Host "  files remaining: $($remaining.Count)"
$remainingPaths = @($remaining | ForEach-Object { $_.FullName })
Invoke-MoveBatch $remainingPaths
Remove-PruneEmpty $Source | Out-Null

Write-Host "==================================================" -ForegroundColor Magenta
Write-Host ("  moved {0} | already there {1} | conflicts {2} | keeps {3} | failed {4}" -f
    $stats.ok, $stats.exists, $stats.conflict, $stats.kept, $stats.fail)
Write-Log ("finish: moved {0} | exists {1} | conflicts {2} | kept {3} | failed {4}" -f
    $stats.ok, $stats.exists, $stats.conflict, $stats.kept, $stats.fail)
Write-Host "  log: $logFile" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Magenta