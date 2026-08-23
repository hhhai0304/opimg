#requires -Version 5.1
<#
.SYNOPSIS
    Optimize-Media - Compress images and videos optimally while keeping the best possible quality.
.DESCRIPTION
    Recursively scans a folder (or a single file) for media, compresses in place using GPU (NVENC)
    or CPU, verifies each output, and only replaces the original when smaller and still readable.
    Reports before/after, savings %, and the tool used. Re-runs automatically skip already-done files.
.EXAMPLE
    .\Optimize-Media.ps1 "\\NAS\share\path\to\media"
    .\Optimize-Media.ps1 "\\NAS\share\Photos" -Preset max -Backup
    .\Optimize-Media.ps1 "D:\Photos\img.jpg"
    .\Optimize-Media.ps1 <path> -WhatIf        # scan and estimate only, no compression
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [Parameter(Position = 1)]
    [ValidateSet('fast', 'balanced', 'max', 'archive')]
    [string]$Preset = 'balanced',

    [ValidateSet('hevc', 'h264', 'av1')]
    [string]$Codec,

    [switch]$Backup,
    [switch]$WhatIf,
    [switch]$Force,
    [double]$MinSaving = 5,

    [string[]]$Include,
    [string[]]$Exclude
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RootDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ToolsDir = Join-Path $script:RootDir 'tools'
$script:TempDir  = Join-Path $script:RootDir 'temp'
$script:LogDir   = Join-Path $script:RootDir 'logs'
$script:BackupDir = Join-Path $script:RootDir 'backup'
$script:ConfigPath = Join-Path $script:RootDir 'config.json'

$script:ImageExt = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.heic', '.heif')
$script:VideoExt = @('.mp4', '.mov', '.mkv', '.avi', '.m4v', '.wmv', '.flv', '.webm', '.ts', '.mts', '.m2ts', '.mpg', '.mpeg', '.3gp')

# ============================================================ helpers
function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N1} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}
function Format-Duration([double]$sec) {
    $t = [TimeSpan]::FromSeconds([math]::Round($sec))
    if ($t.TotalHours -ge 1) { return $t.ToString('h\h\ mm\m') }
    return $t.ToString('m\m\ ss\s')
}
function Write-Info([string]$msg)  { Write-Host $msg -ForegroundColor Gray }
function Write-Ok([string]$msg)    { Write-Host $msg -ForegroundColor Green }
function Write-Skip([string]$msg)  { Write-Host $msg -ForegroundColor DarkGray }
function Write-Warn2([string]$msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err([string]$msg)   { Write-Host $msg -ForegroundColor Red }

# ============================================================ load config
if (-not (Test-Path $script:ConfigPath)) {
    Write-Err "setup.ps1 has not been run yet. Please run: .\setup.ps1 first."
    exit 1
}
$cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
if (-not $cfg.tools.ffmpeg -or -not $cfg.tools.ffprobe) {
    Write-Err "Missing ffmpeg/ffprobe. Re-run .\setup.ps1"
    exit 1
}
$FFMPEG   = [string]$cfg.tools.ffmpeg
$FFPROBE  = [string]$cfg.tools.ffprobe
$OXIPNG   = [string]$cfg.tools.oxipng
$PNGQUANT = [string]$cfg.tools.pngquant
$JPEGTOOL = [string]$cfg.tools.cjpeg          # may be jpegoptim or cjpeg
$JPEGKIND = [string]$cfg.tools.'cjpeg_kind'   # 'jpegoptim' | '' (cjpeg) | $null
$HAS_NVENC = [bool]$cfg.gpu.nvenc
$HAS_AV1NV = [bool]$cfg.gpu.av1_nvenc

foreach ($d in @($script:TempDir, $script:LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# ============================================================ preset config
# Lower CQ = higher quality, larger file
$PRESETS = @{
    fast     = @{ cq = 28; nvPreset = 'p4'; cpuCrf = 26; cpuPreset = 'fast';   jpgQ = 82; pngQ = '75-90'  }
    balanced = @{ cq = 25; nvPreset = 'p6'; cpuCrf = 23; cpuPreset = 'medium'; jpgQ = 85; pngQ = '80-95'  }
    max      = @{ cq = 22; nvPreset = 'p7'; cpuCrf = 20; cpuPreset = 'slow';   jpgQ = 90; pngQ = '85-98'  }
    archive  = @{ cq = 23; nvPreset = 'p6'; cpuCrf = 21; cpuPreset = 'medium'; jpgQ = 88; pngQ = '85-95'  }
}
$P = $PRESETS[$Preset]

# video codec
if (-not $Codec) {
    $Codec = switch ($Preset) {
        'archive' { 'h264' }
        'max'     { if ($HAS_AV1NV) { 'av1' } else { 'hevc' } }
        default   { 'hevc' }
    }
}
# map codec -> actual encoder
$encMap = @{
    hevc = @{ gpu = 'hevc_nvenc'; cpu = 'libx265'; tag = 'hvc1' }
    h264 = @{ gpu = 'h264_nvenc'; cpu = 'libx264'; tag = 'avc1' }
    av1  = @{ gpu = 'av1_nvenc';  cpu = 'libsvtav1'; tag = 'av01' }
}
$useGpu = $HAS_NVENC -and ($Codec -ne 'av1' -or $HAS_AV1NV)
$encoder = if ($useGpu) { $encMap[$Codec].gpu } else { $encMap[$Codec].cpu }

Write-Host "==================================================" -ForegroundColor Magenta
Write-Host "  Optimize-Media  |  preset: $Preset  |  video: $Codec ($encoder$(if($useGpu){' [GPU]'}))" -ForegroundColor Magenta
Write-Host "==================================================" -ForegroundColor Magenta

# ============================================================ collect files
# strip stray quotes when user pastes a quoted string into the prompt
$Path = $Path.Trim().Trim('"', "'")

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Err "Path not found: $Path"
    exit 1
}
$inputItem = Get-Item -LiteralPath $Path
if ($inputItem.PSIsContainer) {
    $allFiles = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)
    $scanRoot = $inputItem.FullName
} else {
    $allFiles = @($inputItem)
    $scanRoot = $inputItem.DirectoryName
}

$mediaFiles = @()
foreach ($f in $allFiles) {
    $ext = $f.Extension.ToLower()
    $isMedia = $script:ImageExt -contains $ext -or $script:VideoExt -contains $ext
    if (-not $isMedia) { continue }
    if ($Include -and ($Include | ForEach-Object { $_.ToLower().TrimStart('.') }) -notcontains $ext.TrimStart('.')) { continue }
    if ($Exclude -and ($Exclude | ForEach-Object { $_.ToLower().TrimStart('.') }) -contains $ext.TrimStart('.')) { continue }
    $kind = if ($script:ImageExt -contains $ext) { 'image' } else { 'video' }
    $mediaFiles += [pscustomobject]@{ File = $f; Kind = $kind; Ext = $ext }
}

if ($mediaFiles.Count -eq 0) {
    Write-Err "No image/video files found in: $Path"
    exit 1
}

$totalBytesBefore = ($mediaFiles | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
$nImg = @($mediaFiles | Where-Object Kind -eq 'image').Count
$nVid = @($mediaFiles | Where-Object Kind -eq 'video').Count
Write-Host "Scanned: $($mediaFiles.Count) files ($nImg images, $nVid videos) - $(Format-Size $totalBytesBefore)" -ForegroundColor Cyan
Write-Info "Source: $scanRoot"
if ($WhatIf) { Write-Warn2 "WhatIf mode: estimate only, no compression will run.`n" }

# ============================================================ history (skip already-processed files)
$historyPath = Join-Path $script:LogDir 'history.csv'
$history = @{}
if ((Test-Path $historyPath) -and (-not $Force)) {
    Import-Csv $historyPath | ForEach-Object { $history[$_.path] = $true }
}

$reportFile = Join-Path $script:LogDir ("report-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".csv")
$results = New-Object System.Collections.Generic.List[object]

# ============================================================ verify + process functions
function Get-VideoDuration([string]$file) {
    try {
        $o = & $FFPROBE -v error -show_entries format=duration -of csv=p=0 $file 2>&1
        return [double]$o
    } catch { return -1 }
}

function Test-VideoValid([string]$file) {
    # decode the whole file; success means it is readable
    & $FFMPEG -v error -i $file -f null - 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Test-ImageValid([string]$file) {
    & $FFMPEG -v error -i $file -f null - 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Backup-Original([string]$srcFile, [string]$root) {
    $rel = $srcFile
    if ($srcFile.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $srcFile.Substring($root.Length).TrimStart('\', '/')
    }
    $dest = Join-Path $script:BackupDir $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $srcFile -Destination $dest -Force
}

function Compress-Image([pscustomobject]$item, [string]$workDir) {
    $src = $item.File.FullName
    $ext = $item.Ext
    $tmp = Join-Path $workDir ("img_" + [guid]::NewGuid().ToString('N') + $ext)
    Copy-Item -LiteralPath $src -Destination $tmp -Force
    $tool = 'none'

    try {
        switch -Regex ($ext) {
            '\.jpe?g$' {
                if ($JPEGTOOL -and $JPEGKIND -eq 'jpegoptim') {
                    # lossless: optimize only, no quality loss
                    & $JPEGTOOL --strip-all --all-progressive $tmp 2>&1 | Out-Null
                    $tool = 'jpegoptim-lossless'
                } elseif ($JPEGTOOL) {
                    # cjpeg (mozjpeg) - re-encode at high quality
                    $tmpOut = "$tmp.out.jpg"
                    & $JPEGTOOL -quality $P.jpgQ -optimize -progressive -outfile $tmpOut $tmp 2>&1 | Out-Null
                    if (Test-Path $tmpOut) { Move-Item $tmpOut $tmp -Force }
                    $tool = "mozjpeg-q$($P.jpgQ)"
                } else {
                    # fallback to ffmpeg mjpeg
                    $tmpOut = "$tmp.out.jpg"
                    & $FFMPEG -y -v error -i $tmp -c:v mjpeg -q:v 2 -map_metadata -1 $tmpOut 2>&1 | Out-Null
                    if (Test-Path $tmpOut) { Move-Item $tmpOut $tmp -Force }
                    $tool = 'ffmpeg-mjpeg'
                }
            }
            '\.png$' {
                # 1) lossless first
                if ($OXIPNG) {
                    & $OXIPNG -o 4 --strip safe $tmp 2>&1 | Out-Null
                    $tool = 'oxipng'
                }
                # 2) if still large, try light lossy with pngquant
                if ($PNGQUANT -and (Get-Item $tmp).Length -gt 200KB) {
                    $tmpQ = "$tmp.q.png"
                    & $PNGQUANT --quality=$($P.pngQ) --speed 1 --strip --force --output $tmpQ $tmp 2>&1 | Out-Null
                    if ((Test-Path $tmpQ) -and ((Get-Item $tmpQ).Length -lt (Get-Item $tmp).Length * 0.92)) {
                        Move-Item $tmpQ $tmp -Force
                        $tool = "oxipng+pngquant($($P.pngQ))"
                    } else {
                        Remove-Item $tmpQ -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            '\.gif$' {
                $tmpOut = "$tmp.out.gif"
                & $FFMPEG -y -v error -i $tmp -map_metadata -1 $tmpOut 2>&1 | Out-Null
                if ((Test-Path $tmpOut) -and ((Get-Item $tmpOut).Length -lt (Get-Item $tmp).Length)) { Move-Item $tmpOut $tmp -Force }
                $tool = 'ffmpeg-gif'
            }
            '\.webp$' {
                $tmpOut = "$tmp.out.webp"
                & $FFMPEG -y -v error -i $tmp -c:v libwebp -quality 85 -map_metadata -1 $tmpOut 2>&1 | Out-Null
                if ((Test-Path $tmpOut) -and ((Get-Item $tmpOut).Length -lt (Get-Item $tmp).Length)) { Move-Item $tmpOut $tmp -Force }
                $tool = 'libwebp-q85'
            }
            default {
                # bmp/tiff/heic... -> light re-encode via ffmpeg
                $tmpOut = "$tmp.out$ext"
                & $FFMPEG -y -v error -i $tmp -map_metadata -1 $tmpOut 2>&1 | Out-Null
                if ((Test-Path $tmpOut) -and ((Get-Item $tmpOut).Length -lt (Get-Item $tmp).Length)) { Move-Item $tmpOut $tmp -Force }
                $tool = 'ffmpeg'
            }
        }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }

    if (-not (Test-ImageValid $tmp)) {
        return @{ ok = $false; error = 'output is unreadable' }
    }
    return @{ ok = $true; outFile = $tmp; tool = $tool }
}

function Compress-Video([pscustomobject]$item, [string]$workDir, [int]$index, [int]$total) {
    $src = $item.File.FullName
    $tmp = Join-Path $workDir ("vid_" + [guid]::NewGuid().ToString('N') + '.mp4')
    $durBefore = Get-VideoDuration $src

    # pick parameters based on encoder
    $encArgs = @()
    if ($useGpu) {
        $encArgs = @('-c:v', $encoder, '-preset', $P.nvPreset, '-cq', $P.cq, '-rc', 'constqp')
        if ($Codec -eq 'av1') { $encArgs = @('-c:v', $encoder, '-preset', $P.nvPreset, '-cq', $P.cq) }
    } else {
        $encArgs = @('-c:v', $encoder, '-crf', $P.cpuCrf, '-preset', $P.cpuPreset)
        if ($Codec -eq 'hevc') { $encArgs += @('-tag:v', 'hvc1') }
    }

    $argsList = @('-y', '-v', 'error', '-i', $src) + $encArgs + @('-c:a', 'copy', '-c:s', 'copy', '-map_metadata', '-1', '-movflags', '+faststart', $tmp)
    & $FFMPEG @argsList 2>&1 | Out-Null

    if (-not (Test-Path $tmp)) {
        return @{ ok = $false; error = 'ffmpeg did not produce an output' }
    }
    # verify
    if (-not (Test-VideoValid $tmp)) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return @{ ok = $false; error = 'output failed to decode' }
    }
    $durAfter = Get-VideoDuration $tmp
    if ($durBefore -gt 0 -and $durAfter -gt 0 -and [math]::Abs($durAfter - $durBefore) -gt 1.0) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return @{ ok = $false; error = "duration mismatch ($durBefore vs $durAfter)" }
    }
    $tool = "$encoder cq$($P.cq)" + $(if ($useGpu) { ' [GPU]' } else { ' [CPU]' })
    return @{ ok = $true; outFile = $tmp; tool = $tool }
}

# ============================================================ main loop
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$done = 0; $skipped = 0; $failed = 0
$savedBytes = 0
$processedBytes = 0
$i = 0

foreach ($item in $mediaFiles) {
    $i++
    $f = $item.File
    $sizeBefore = $f.Length
    $relName = if ($f.FullName.StartsWith($scanRoot, [StringComparison]::OrdinalIgnoreCase)) { $f.FullName.Substring($scanRoot.Length).TrimStart('\') } else { $f.Name }

    # skip already processed
    if ($history.ContainsKey($f.FullName)) {
        $skipped++
        Write-Skip ("[{0}/{1}] SKIP (already done): {2}" -f $i, $mediaFiles.Count, $relName)
        continue
    }

    if ($WhatIf) {
        Write-Info ("[{0}/{1}] Would compress: {2} ({3})" -f $i, $mediaFiles.Count, $relName, (Format-Size $sizeBefore))
        continue
    }

    $fileWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $res = if ($item.Kind -eq 'image') { Compress-Image $item $script:TempDir } else { Compress-Video $item $script:TempDir $i $mediaFiles.Count }
    $fileWatch.Stop()

    if (-not $res.ok) {
        $failed++
        Write-Err ("[{0}/{1}] FAIL: {2} - {3}" -f $i, $mediaFiles.Count, $relName, $res.error)
        $results.Add([pscustomobject]@{
            path = $f.FullName; kind = $item.Kind; before = $sizeBefore; after = $sizeBefore
            saved_pct = 0; tool = ''; seconds = [math]::Round($fileWatch.Elapsed.TotalSeconds, 1); status = "fail: $($res.error)"
        })
        continue
    }

    $sizeAfter = (Get-Item $res.outFile).Length
    $savingPct = if ($sizeBefore -gt 0) { (1 - $sizeAfter / $sizeBefore) * 100 } else { 0 }

    if ($savingPct -lt $MinSaving) {
        $skipped++
        Remove-Item $res.outFile -Force -ErrorAction SilentlyContinue
        Write-Skip ("[{0}/{1}] SKIP (<{2}% saving): {3} ({4} -> {5})" -f $i, $mediaFiles.Count, $MinSaving, $relName, (Format-Size $sizeBefore), (Format-Size $sizeAfter))
        $results.Add([pscustomobject]@{
            path = $f.FullName; kind = $item.Kind; before = $sizeBefore; after = $sizeBefore
            saved_pct = 0; tool = $res.tool; seconds = [math]::Round($fileWatch.Elapsed.TotalSeconds, 1); status = 'skipped-small-gain'
        })
        continue
    }

    # backup + replace
    try {
        if ($Backup) { Backup-Original $f.FullName $scanRoot }
        Copy-Item -LiteralPath $res.outFile -Destination $f.FullName -Force
        Remove-Item $res.outFile -Force -ErrorAction SilentlyContinue

        $done++
        $savedBytes += ($sizeBefore - $sizeAfter)
        $processedBytes += $sizeBefore

        $pctTotal = if ($totalBytesBefore -gt 0) { ($processedBytes / $totalBytesBefore) * 100 } else { 0 }
        $eta = if ($processedBytes -gt 0) { ($stopwatch.Elapsed.TotalSeconds / $processedBytes) * ($totalBytesBefore - $processedBytes) } else { 0 }

        Write-Ok ("[{0}/{1}] {2}  {3} -> {4}  (-{5:N0}%)  {6}  {7}" -f
            $i, $mediaFiles.Count, $relName,
            (Format-Size $sizeBefore), (Format-Size $sizeAfter), $savingPct,
            $res.tool, (Format-Duration $fileWatch.Elapsed.TotalSeconds))
        Write-Info ("    Overall: {0:N0}% | saved {1} | ETA ~{2}" -f $pctTotal, (Format-Size $savedBytes), (Format-Duration $eta))

        $results.Add([pscustomobject]@{
            path = $f.FullName; kind = $item.Kind; before = $sizeBefore; after = $sizeAfter
            saved_pct = [math]::Round($savingPct, 1); tool = $res.tool; seconds = [math]::Round($fileWatch.Elapsed.TotalSeconds, 1); status = 'ok'
        })
    } catch {
        $failed++
        Write-Err ("[{0}/{1}] FAIL while replacing: {2} - {3}" -f $i, $mediaFiles.Count, $relName, $_.Exception.Message)
        Remove-Item $res.outFile -Force -ErrorAction SilentlyContinue
    }
}

$stopwatch.Stop()

# ============================================================ report
if (-not $WhatIf -and $results.Count -gt 0) {
    $results | Export-Csv -LiteralPath $reportFile -NoTypeInformation -Encoding UTF8
    # update history (only successfully compressed files) - append to existing file
    $okRows = $results | Where-Object { $_.status -eq 'ok' } | Select-Object @{n='path';e={$_.path}}, @{n='date';e={(Get-Date).ToString('s')}}
    if ($okRows) {
        $okRows | Export-Csv -LiteralPath $historyPath -NoTypeInformation -Encoding UTF8 -Append
    }
}

Write-Host "`n==================================================" -ForegroundColor Magenta
Write-Host "  RESULTS" -ForegroundColor Magenta
Write-Host "==================================================" -ForegroundColor Magenta

if ($WhatIf) {
    Write-Host "WhatIf mode - nothing was compressed. Total: $($mediaFiles.Count) files, $(Format-Size $totalBytesBefore)"
    if ($Host.Name -eq 'ConsoleHost' -and -not $env:OM_IGNORE_PAUSE) {
        Write-Host "`nPress Enter to close..." -ForegroundColor Yellow
        Read-Host | Out-Null
    }
    exit 0
}

$afterBytes = $totalBytesBefore - $savedBytes
$totalPct = if ($totalBytesBefore -gt 0) { ($savedBytes / $totalBytesBefore) * 100 } else { 0 }

Write-Host ("  Compressed : {0} files" -f $done)
Write-Host ("  Skipped    : {0} files" -f $skipped)
if ($failed -gt 0) { Write-Host ("  Failed     : {0} files" -f $failed) -ForegroundColor Red }
Write-Host ("  Before     : {0}" -f (Format-Size $totalBytesBefore))
Write-Host ("  After      : {0}" -f (Format-Size $afterBytes))
Write-Host ("  Saved      : {0}  ({1:N1}%)" -f (Format-Size $savedBytes), $totalPct) -ForegroundColor Green
Write-Host ("  Time       : {0}" -f (Format-Duration $stopwatch.Elapsed.TotalSeconds))

# breakdown by kind
foreach ($k in @('image', 'video')) {
    $rows = @($results | Where-Object { $_.kind -eq $k -and $_.status -eq 'ok' })
    if ($rows.Count -gt 0) {
        $b = ($rows | Measure-Object before -Sum).Sum
        $a = ($rows | Measure-Object after -Sum).Sum
        $s = $b - $a
        Write-Host ("    {0,-6}: {1,4} files | {2} -> {3} | saved {4} ({5:N0}%)" -f
            $(if ($k -eq 'image') { 'Images' } else { 'Videos' }), $rows.Count,
            (Format-Size $b), (Format-Size $a), (Format-Size $s), (($s / [math]::Max($b, 1)) * 100))
    }
}

Write-Host "`nDetailed report: $reportFile" -ForegroundColor Cyan
if ($Backup) { Write-Host "Originals backed up to: $script:BackupDir" -ForegroundColor Cyan }

# keep the window open when launched by double-click (powershell.exe opens a new console)
if ($Host.Name -eq 'ConsoleHost' -and -not $env:OM_IGNORE_PAUSE) {
    Write-Host "`nPress Enter to close..." -ForegroundColor Yellow
    Read-Host | Out-Null
}
