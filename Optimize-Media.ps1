#requires -Version 5.1
<#
.SYNOPSIS
    Optimize-Media - Compress images and videos optimally while keeping the best possible quality.
.DESCRIPTION
    Recursively scans a folder (or a single file) for media, compresses in parallel using GPU
    (NVENC) and CPU worker pools, verifies each output, and only replaces the original when
    smaller and valid. Re-runs automatically skip already-processed files.
    Parallelism is tuned automatically from config.json (run Benchmark-Machine.ps1 to re-measure,
    or edit the "performance" section by hand).
.EXAMPLE
    .\Optimize-Media.ps1 "\\NAS\share\path\to\media"
    .\Optimize-Media.ps1 "\\NAS\share\Photos" -Preset max -Backup
    .\Optimize-Media.ps1 "D:\Photos\img.jpg"
    .\Optimize-Media.ps1 "folder1" "folder2" "folder3"   # multiple folders in one run
    .\Optimize-Media.ps1 <path...> -AV1              # force AV1 video encoding (needs RTX 40xx for GPU speed)
    .\Optimize-Media.ps1 <path...> -WhatIf          # scan and estimate only, no compression
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Path,

    [Parameter(Position = 1)]
    [ValidateSet('fast', 'balanced', 'max', 'archive')]
    [string]$Preset = 'balanced',

    [ValidateSet('hevc', 'h264', 'av1')]
    [string]$Codec,

    # shorthand for -Codec av1
    [switch]$AV1,

    [switch]$Backup,
    [switch]$WhatIf,
    [switch]$Force,
    [double]$MinSaving = 5,

    [string[]]$Include,
    [string[]]$Exclude,

    # 0 = use config.json performance defaults
    [int]$ImageWorkers = 0,
    [int]$VideoWorkers = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RootDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:TempDir   = Join-Path $script:RootDir 'temp'
$script:LogDir    = Join-Path $script:RootDir 'logs'
$script:BackupDir = Join-Path $script:RootDir 'backup'
$script:ConfigPath = Join-Path $script:RootDir 'config.json'

# Audio codecs ffmpeg can mux into MP4 without re-encoding. Opus/Vorbis are
# deliberately absent (WebM audio) so those files are skipped safely.
$script:Mp4AudioCodecs = @('aac', 'mp3', 'mp2', 'ac3', 'eac3', 'alac', 'flac')
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
    $t = [TimeSpan]::FromSeconds([math]::Round([math]::Max(0, $sec)))
    if ($t.TotalHours -ge 1) { return $t.ToString('h\h\ mm\m') }
    return $t.ToString('m\m\ ss\s')
}
function Write-Info([string]$msg)  { Write-Host $msg -ForegroundColor Gray }
function Write-Ok([string]$msg)    { Write-Host $msg -ForegroundColor Green }
function Write-Warn2([string]$msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err([string]$msg)   { Write-Host $msg -ForegroundColor Red }

# Windows toast (balloon) notification so the user is alerted even when the
# console is backgrounded, plus a chime. Uses a real message pump for a
# reliable balloon. On any failure it just flashes the console title.
function Show-FinishedNotification {
    param([string]$Title, [string]$Body)
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        Add-Type -AssemblyName System.Drawing | Out-Null
        $iconPath = [System.Environment]::GetFolderPath('System') + '\notepad.exe'
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = New-Object System.Drawing.Icon($iconPath)
        $notify.Visible = $true
        $notify.BalloonTipTitle = $Title
        $notify.BalloonTipText  = $Body
        $notify.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Info
        $notify.ShowBalloonTip(10000)
        # Pump Windows messages so the balloon actually renders for ~10s.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 10) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        $notify.Dispose()
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
    } catch {
        try { [Console]::Title = "Optimize-Media - FINISHED: $Title ($Body)" } catch { }
    }
}

# Argument channel (direct invocation, and the .cmd wrapper).
# PowerShell has already tokenized the command line, so each $Path element is
# exactly one path - spaces intact, quotes stripped. The only extra case is the
# .cmd wrapper, which joins whole paths with '|' (illegal in Windows filenames);
# those segments are complete paths and must NOT be split on whitespace.
function Expand-PathArg([string]$entry) {
    $out = @()
    if (-not $entry) { return ,$out }
    foreach ($seg in $entry -split '\|') {
        $t = $seg.Trim().Trim('"', "'")
        if ($t -ne '') { $out += $t }
    }
    return ,$out
}

# Prompt channel (Read-Host): one raw line typed or pasted by the user.
# Explorer quotes only names that contain spaces, so a single line routinely
# mixes quoted and bare paths - both forms must survive.
# When the line contains no quotes at all we treat it as ONE path, so a manually
# typed unquoted path with spaces (C:\my photos) still works.
function Split-PathLine([string]$raw) {
    $out = @()
    if (-not $raw) { return ,$out }
    $raw = $raw.Trim()
    if ($raw -eq '') { return ,$out }

    # No quotes anywhere: the whole line is a single path.
    if ($raw -notmatch '"') {
        $out += $raw.Trim("'")
        return ,$out
    }

    # Mixed line: quoted runs are one path each, bare runs are whitespace
    # separated (Explorer never leaves a spaced name unquoted).
    foreach ($m in [regex]::Matches($raw, '"([^"]*)"|([^"\s]+)')) {
        $t = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        $t = $t.Trim()
        if ($t -ne '') { $out += $t }
    }
    return ,$out
}

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
$JPEGTOOL = [string]$cfg.tools.cjpeg
$JPEGKIND = [string]$cfg.tools.'cjpeg_kind'
$HAS_NVENC = [bool]$cfg.gpu.nvenc
$HAS_AV1NV = [bool]$cfg.gpu.av1_nvenc

# performance defaults (fallbacks if benchmark has not run yet)
$perfProp = $cfg.PSObject.Properties['performance']
$perf = @{}
if ($perfProp) { $perfProp.Value.PSObject.Properties | ForEach-Object { $perf[$_.Name] = $_.Value } }
$logical = if ($perf.logicalCores) { [int]$perf.logicalCores } else { [int](Get-CimInstance Win32_Processor).NumberOfLogicalProcessors }
if ($ImageWorkers -le 0) { $ImageWorkers = if ($perf.imageWorkers) { [int]$perf.imageWorkers } else { [math]::Max(2, $logical - 4) } }
if ($VideoWorkers -le 0) {
    $VideoWorkers = if ($perf.videoWorkers) { [int]$perf.videoWorkers }
    elseif ($HAS_NVENC) { 2 } else { 2 }
}
$ImageWorkers = [math]::Max(1, $ImageWorkers)
$VideoWorkers = [math]::Max(1, $VideoWorkers)

foreach ($d in @($script:TempDir, $script:LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# ============================================================ preset config
$PRESETS = @{
    fast     = @{ cq = 28; nvPreset = 'p4'; cpuCrf = 26; cpuPreset = 'fast';   jpgQ = 82; pngQ = '75-90'  }
    balanced = @{ cq = 25; nvPreset = 'p6'; cpuCrf = 23; cpuPreset = 'medium'; jpgQ = 85; pngQ = '80-95'  }
    max      = @{ cq = 22; nvPreset = 'p7'; cpuCrf = 20; cpuPreset = 'slow';   jpgQ = 90; pngQ = '85-98'  }
    archive  = @{ cq = 23; nvPreset = 'p6'; cpuCrf = 21; cpuPreset = 'medium'; jpgQ = 88; pngQ = '85-95'  }
}
$P = $PRESETS[$Preset]

# codec resolution: -Codec/-AV1 flags > machine default from config.json > preset
if ($AV1) { $Codec = 'av1' }
if (-not $Codec) {
    $cfgCodecProp = $cfg.PSObject.Properties['codec']
    if ($cfgCodecProp -and @('hevc', 'h264', 'av1') -contains $cfgCodecProp.Value) { $Codec = [string]$cfgCodecProp.Value }
}
if (-not $Codec) {
    $Codec = switch ($Preset) {
        'archive' { 'h264' }
        'max'     { if ($HAS_AV1NV) { 'av1' } else { 'hevc' } }
        default   { 'hevc' }
    }
}
$encMap = @{
    hevc = @{ gpu = 'hevc_nvenc'; cpu = 'libx265'; tag = 'hvc1' }
    h264 = @{ gpu = 'h264_nvenc'; cpu = 'libx264'; tag = 'avc1' }
    av1  = @{ gpu = 'av1_nvenc';  cpu = 'libsvtav1'; tag = 'av01' }
}
$useGpu = $HAS_NVENC -and ($Codec -ne 'av1' -or $HAS_AV1NV)
$encoder = if ($useGpu) { $encMap[$Codec].gpu } else { $encMap[$Codec].cpu }
if ($Codec -eq 'av1' -and -not $HAS_AV1NV) {
    Write-Warn2 "AV1 NVENC is not available on this GPU -> falling back to CPU encoding (slow)"
}

Write-Host "==================================================" -ForegroundColor Magenta
Write-Host "  Optimize-Media  |  preset: $Preset  |  video: $Codec ($encoder$(if($useGpu){' [GPU]'}))" -ForegroundColor Magenta
Write-Host "  Workers: $ImageWorkers images + $VideoWorkers videos (parallel)" -ForegroundColor Magenta
Write-Host "==================================================" -ForegroundColor Magenta

# ============================================================ collect files
$mediaFiles = @()
$sourceRoots = @()

# Resolve the path list. A direct run with no arguments gets one friendly
# prompt (no per-item Path[0]/Path[1] prompts), and pasted multiple quoted
# paths are split correctly.
$pathList = @()
foreach ($entry in $Path) { $pathList += @(Expand-PathArg ([string]$entry)) }
if ($pathList.Count -eq 0) {
    $line = Read-Host 'Enter path(s) - drag/paste one or more folders (quote any name containing spaces)'
    $pathList = @(Split-PathLine $line)
}
Write-Host ("Resolved {0} input path(s):" -f $pathList.Count)
$pathList | ForEach-Object { Write-Host "  - $_" }
if ($pathList.Count -eq 0) {
    Write-Err "No path was given."
    exit 1
}

foreach ($curPath in $pathList) {
    if (-not (Test-Path -LiteralPath $curPath)) {
        Write-Err "Path not found: $curPath"
        exit 1
    }
    $inputItem = Get-Item -LiteralPath $curPath
    if ($inputItem.PSIsContainer) {
        $subFiles = @(Get-ChildItem -LiteralPath $curPath -Recurse -File -ErrorAction SilentlyContinue)
        $root = $inputItem.FullName
    } else {
        $subFiles = @($inputItem)
        $root = $inputItem.DirectoryName
    }
    $sourceRoots += $root

    foreach ($f in $subFiles) {
        $ext = $f.Extension.ToLower()
        $isMedia = $script:ImageExt -contains $ext -or $script:VideoExt -contains $ext
        if (-not $isMedia) { continue }
        if ($Include -and ($Include | ForEach-Object { $_.ToLower().TrimStart('.') }) -notcontains $ext.TrimStart('.')) { continue }
        if ($Exclude -and ($Exclude | ForEach-Object { $_.ToLower().TrimStart('.') }) -contains $ext.TrimStart('.')) { continue }
        $kind = if ($script:ImageExt -contains $ext) { 'image' } else { 'video' }
        $mediaFiles += [pscustomobject]@{ File = $f; Kind = $kind; Ext = $ext; Root = $root }
    }
}

if ($mediaFiles.Count -eq 0) {
    Write-Err "No image/video files found in: $($sourceRoots -join '; ')"
    exit 1
}

$totalBytesBefore = ($mediaFiles | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
$nImg = @($mediaFiles | Where-Object Kind -eq 'image').Count
$nVid = @($mediaFiles | Where-Object Kind -eq 'video').Count
Write-Host "Scanned: $($mediaFiles.Count) files ($nImg images, $nVid videos) - $(Format-Size $totalBytesBefore)" -ForegroundColor Cyan
Write-Info "Source: $($sourceRoots -join '; ')"

# ============================================================ history (skip already-processed files)
$historyPath = Join-Path $script:LogDir 'history.csv'
$history = @{}
if ((Test-Path $historyPath) -and (-not $Force)) {
    Import-Csv $historyPath | ForEach-Object { $history[$_.path] = $true }
}

# split into work queues (skip history + non-target files)
$imgQueue = @($mediaFiles | Where-Object { $_.Kind -eq 'image' -and -not $history.ContainsKey($_.File.FullName) })
$vidQueue = @($mediaFiles | Where-Object { $_.Kind -eq 'video' -and -not $history.ContainsKey($_.File.FullName) })
$preSkipped = $mediaFiles.Count - $imgQueue.Count - $vidQueue.Count
if ($preSkipped -gt 0) { Write-Info "Already processed earlier: $preSkipped files (skipped)" }

if ($WhatIf) {
    Write-Warn2 "`nWhatIf mode: estimate only, no compression will run."
    $i = 0
    foreach ($q in @($vidQueue + $imgQueue)) {
        $i++
        Write-Info ("[{0}/{1}] Would compress: {2} ({3})" -f $i, ($vidQueue.Count + $imgQueue.Count), $q.File.Name, (Format-Size $q.File.Length))
    }
    Write-Host "`nTotal: $($mediaFiles.Count) files, $(Format-Size $totalBytesBefore)"
    if ($Host.Name -eq 'ConsoleHost' -and -not $env:OM_IGNORE_PAUSE) {
        Write-Host "`nPress Enter to close..." -ForegroundColor Yellow
        Read-Host | Out-Null
    }
    exit 0
}

if (($imgQueue.Count + $vidQueue.Count) -eq 0) {
    Write-Ok "Nothing to do - every file was already processed."
    Show-FinishedNotification -Title "Optimize-Media finished" -Body "Nothing to do - every file was already processed."
    exit 0
}

# ============================================================ worker script block
$workerScript = {
    param([object]$item, [hashtable]$ctx, [hashtable]$state)

    function Get-VideoDuration([string]$file) {
        try {
            $o = & $ctx.FFPROBE -v error -show_entries format=duration -of csv=p=0 $file 2>&1
            return [double]$o
        } catch { return -1 }
    }
    function Test-MediaValid([string]$file) {
        & $ctx.FFMPEG -v error -i $file -f null - 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    # Probe the stream layout; returns an error string when converting would
    # lose data (extra tracks, subtitles, attachments, non-MP4 audio...),
    # or $null when safe to proceed.
    function Get-SkipReason([string]$file) {
        try {
            $videoStreams = @(& $ctx.FFPROBE -v error -select_streams V -show_entries stream=index -of csv=p=0 $file 2>$null | Where-Object { $_ -ne '' })
            if ($videoStreams.Count -eq 0) { return 'no video stream' }
            if ($videoStreams.Count -gt 1) { return ('multiple video streams ({0})' -f $videoStreams.Count) }

            $firstCodec = (& $ctx.FFPROBE -v error -select_streams V:0 -show_entries stream=codec_name -of csv=p=0 $file 2>$null | Select-Object -First 1)
            if ($firstCodec -eq $ctx.TargetCodecName) { return "already $($ctx.Codec)" }

            $subs = @(& $ctx.FFPROBE -v error -select_streams s -show_entries stream=index -of csv=p=0 $file 2>$null | Where-Object { $_ -ne '' })
            if ($subs.Count -gt 0) { return 'subtitle streams would not survive the container change' }

            $attach = @(& $ctx.FFPROBE -v error -select_streams t -show_entries stream=index -of csv=p=0 $file 2>$null | Where-Object { $_ -ne '' })
            if ($attach.Count -gt 0) { return 'embedded attachments would be lost' }

            $audioCodecs = @(& $ctx.FFPROBE -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 $file 2>$null | Where-Object { $_ })
            foreach ($c in $audioCodecs) {
                if ($ctx.Mp4AudioCodecs -notcontains $c) { return "audio '$c' cannot be copied into MP4" }
            }
            return $null
        } catch {
            return "probe failed: $($_.Exception.Message)"
        }
    }
    function Update-Active([string]$label) {
        [System.Threading.Monitor]::Enter($state.SyncRoot)
        try {
            if ($label) { $state.Active[$item.File.FullName] = $label }
            else { $state.Active.Remove($item.File.FullName) }
        } finally { [System.Threading.Monitor]::Exit($state.SyncRoot) }
    }

    $src = $item.File.FullName
    $ext = $item.Ext
    $sizeBefore = $item.File.Length
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $tmp = $null
    # non-null when a successful result must be saved under a new extension (.mov -> .mp4, .heic/.heif -> .jpg)
    $targetExt = $null

    try {
        # videos show whether they run on the GPU (NVENC) or CPU encoder
        $activeLabel = $item.File.Name
        if ($item.Kind -eq 'video') {
            $activeLabel += $(if ($ctx.useGpu) { ' [GPU]' } else { ' [CPU]' })
        }
        Update-Active $activeLabel

        if ($item.Kind -eq 'image') {
            $tmp = Join-Path $ctx.TempDir ("img_" + [guid]::NewGuid().ToString('N') + $ext)
            Copy-Item -LiteralPath $src -Destination $tmp -Force
            $tool = 'none'

            switch -Regex ($ext) {
                '\.jpe?g$' {
                    if ($ctx.JPEGTOOL -and $ctx.JPEGKIND -eq 'jpegoptim') {
                        # lossless re-compress, KEEP all EXIF (date taken, GPS, camera info)
                        & $ctx.JPEGTOOL --keep-all --all-progressive $tmp 2>&1 | Out-Null
                        $tool = 'jpegoptim-lossless+exif'
                    } elseif ($ctx.JPEGTOOL) {
                        $tmpOut = "$tmp.out.jpg"
                        & $ctx.JPEGTOOL -quality $ctx.jpgQ -optimize -progressive -outfile $tmpOut $tmp 2>&1 | Out-Null
                        if (Test-Path $tmpOut) { Move-Item $tmpOut $tmp -Force }
                        $tool = "mozjpeg-q$($ctx.jpgQ)"
                    } else {
                        $tmpOut = "$tmp.out.jpg"
                        & $ctx.FFMPEG -y -v error -i $tmp -c:v mjpeg -q:v 2 $tmpOut 2>&1 | Out-Null
                        if (Test-Path $tmpOut) { Move-Item $tmpOut $tmp -Force }
                        $tool = 'ffmpeg-mjpeg'
                    }
                }
                '\.png$' {
                    if ($ctx.OXIPNG) {
                        & $ctx.OXIPNG -o 4 --strip safe $tmp 2>&1 | Out-Null
                        $tool = 'oxipng'
                    }
                    if ($ctx.PNGQUANT -and (Get-Item $tmp).Length -gt 200KB) {
                        $tmpQ = "$tmp.q.png"
                        & $ctx.PNGQUANT --quality=$($ctx.pngQ) --speed 1 --force --output $tmpQ $tmp 2>&1 | Out-Null
                        if ((Test-Path $tmpQ) -and ((Get-Item $tmpQ).Length -lt (Get-Item $tmp).Length * 0.92)) {
                            Move-Item $tmpQ $tmp -Force
                            $tool = "oxipng+pngquant($($ctx.pngQ))"
                        } else {
                            Remove-Item $tmpQ -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                '\.gif$' {
                    $tmpOut = "$tmp.out.gif"
                    & $ctx.FFMPEG -y -v error -i $tmp $tmpOut 2>&1 | Out-Null
                    if ((Test-Path $tmpOut) -and ((Get-Item $tmpOut).Length -lt (Get-Item $tmp).Length)) { Move-Item $tmpOut $tmp -Force }
                    $tool = 'ffmpeg-gif'
                }
                '\.webp$' {
                    $tmpOut = "$tmp.out.webp"
                    & $ctx.FFMPEG -y -v error -i $tmp -c:v libwebp -quality 85 $tmpOut 2>&1 | Out-Null
                    if ((Test-Path $tmpOut) -and ((Get-Item $tmpOut).Length -lt (Get-Item $tmp).Length)) { Move-Item $tmpOut $tmp -Force }
                    $tool = 'libwebp-q85'
                }
                '\.heic$|\.heif$' {
                    # Convert HEIC/HEIF photos to JPEG, keeping EXIF metadata
                    # (date taken, camera, GPS) via -map_metadata.
                    $tmpOut = "$tmp.conv.jpg"
                    & $ctx.FFMPEG -y -v error -i $tmp -map_metadata 0 -c:v mjpeg -q:v 2 $tmpOut 2>&1 | Out-Null
                    if ((Test-Path $tmpOut) -and (Test-MediaValid $tmpOut)) {
                        Remove-Item -LiteralPath $tmp -Force
                        Move-Item -LiteralPath $tmpOut -Destination $tmp -Force
                        $targetExt = '.jpg'
                        $tool = 'ffmpeg-mjpeg'
                        # optional extra lossless/lossy pass with the JPEG optimizer
                        if ($ctx.JPEGTOOL -and $ctx.JPEGKIND -eq 'jpegoptim') {
                            & $ctx.JPEGTOOL --keep-all --all-progressive $tmp 2>&1 | Out-Null
                            $tool = 'jpegoptim-lossless+exif'
                        } elseif ($ctx.JPEGTOOL) {
                            $tmpQ = "$tmp.q.jpg"
                            & $ctx.JPEGTOOL -quality $ctx.jpgQ -optimize -progressive -outfile $tmpQ $tmp 2>&1 | Out-Null
                            if ((Test-Path $tmpQ) -and ((Get-Item $tmpQ).Length -lt (Get-Item $tmp).Length)) {
                                Move-Item -LiteralPath $tmpQ -Destination $tmp -Force
                                $tool = "mozjpeg-q$($ctx.jpgQ)"
                            } else {
                                Remove-Item -LiteralPath $tmpQ -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }
                }
                default {
                    $tmpOut = "$tmp.out$ext"
                    & $ctx.FFMPEG -y -v error -i $tmp $tmpOut 2>&1 | Out-Null
                    if ((Test-Path $tmpOut) -and ((Get-Item $tmpOut).Length -lt (Get-Item $tmp).Length)) { Move-Item $tmpOut $tmp -Force }
                    $tool = 'ffmpeg'
                }
            }

            if (-not (Test-MediaValid $tmp)) { throw 'output is unreadable' }

        } else {
            # -------- video --------
            $tmp = Join-Path $ctx.TempDir ("vid_" + [guid]::NewGuid().ToString('N') + '.mp4')
            $durBefore = Get-VideoDuration $src

            # never convert when the container change could lose data
            $skipReason = Get-SkipReason $src
            if ($skipReason) {
                return [pscustomobject]@{
                    path = $src; kind = $item.Kind; before = $sizeBefore; after = $sizeBefore
                    saved_pct = 0; tool = ''; seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
                    status = "skip: $skipReason"
                }
            }

            # capture container metadata from the ORIGINAL (NVENC does not carry creation_time over)
            $origMeta = @{}
            try {
                $tagsJson = & $ctx.FFPROBE -v error -show_entries format_tags -of json $src 2>&1 | Out-String
                # regex instead of ConvertFrom-Json: the JSON parser coerces ISO
                # date strings (creation_time) into DateTime and corrupts them
                foreach ($m in [regex]::Matches($tagsJson, '"([^"]+)"\s*:\s*"((?:[^"\\]|\\.)*)"')) {
                    $origMeta[$m.Groups[1].Value] = $m.Groups[2].Value
                }
            } catch { }

            $encArgs = @()
            if ($ctx.useGpu) {
                $encArgs = @('-c:v', $ctx.encoder, '-preset', $ctx.nvPreset, '-cq', $ctx.cq, '-rc', 'constqp')
                if ($ctx.Codec -eq 'av1') { $encArgs = @('-c:v', $ctx.encoder, '-preset', $ctx.nvPreset, '-cq', $ctx.cq) }
            } else {
                $encArgs = @('-c:v', $ctx.encoder, '-crf', $ctx.cpuCrf, '-preset', $ctx.cpuPreset)
                if ($ctx.Codec -eq 'hevc') { $encArgs += @('-tag:v', 'hvc1') }
            }
            $tool = "$($ctx.encoder) cq$($ctx.cq)" + $(if ($ctx.useGpu) { ' [GPU]' } else { ' [CPU]' })

            # re-apply original container metadata (recording date, title...) after the encoder args
            $metaArgs = @()
            foreach ($k in $origMeta.Keys) { $metaArgs += @('-metadata', "$k=$($origMeta[$k])") }

            # live per-file progress: ffmpeg writes key=value stats to this file
            # and the main thread reads it while the encode runs
            $progFile = Join-Path $ctx.TempDir ("prog_" + [guid]::NewGuid().ToString('N') + '.txt')
            [System.Threading.Monitor]::Enter($state.SyncRoot)
            try { $state.Prog[$src] = @{ File = $progFile; Dur = [double]$durBefore } } finally { [System.Threading.Monitor]::Exit($state.SyncRoot) }

            # explicit stream maps so nothing depends on ffmpeg defaults:
            # first video stream + ALL audio tracks, audio bit-exact
            $argsList = @('-y', '-v', 'error', '-i', $src, '-map', '0:v:0', '-map', '0:a?') +
                $encArgs + @('-c:a', 'copy', '-movflags', '+faststart', '-progress', $progFile, '-nostats') +
                $metaArgs + @($tmp)
            & $ctx.FFMPEG @argsList 2>&1 | Out-Null

            if (-not (Test-Path $tmp)) { throw 'ffmpeg did not produce an output' }
            if (-not (Test-MediaValid $tmp)) { throw 'output failed to decode' }
            $durAfter = Get-VideoDuration $tmp
            if ($durBefore -gt 0 -and $durAfter -gt 0 -and [math]::Abs($durAfter - $durBefore) -gt 1.0) {
                throw "duration mismatch ($durBefore vs $durAfter)"
            }
            # every video is written back as a real .mp4 container on success
            if ($ext -notin @('.mp4', '.m4v')) { $targetExt = '.mp4' }
        }

        $sizeAfter = (Get-Item $tmp).Length
        $savingPct = if ($sizeBefore -gt 0) { (1 - $sizeAfter / $sizeBefore) * 100 } else { 0 }

        if ($savingPct -lt $ctx.MinSaving) {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{
                path = $src; kind = $item.Kind; before = $sizeBefore; after = $sizeBefore
                saved_pct = 0; tool = $tool; seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
                status = 'skipped-small-gain'
            }
        }

        # final destination path (.mov -> .mp4, .heic/.heif -> .jpg)
        $finalPath = $src
        if ($targetExt) {
            $finalPath = [System.IO.Path]::ChangeExtension($src, $targetExt)
            if (Test-Path -LiteralPath $finalPath) {
                throw "cannot rename: destination already exists: $finalPath"
            }
        }

        # backup + replace
        if ($ctx.Backup) {
            $rel = $src
            if ($src.StartsWith($item.Root, [StringComparison]::OrdinalIgnoreCase)) {
                $rel = $src.Substring($item.Root.Length).TrimStart('\', '/')
            }
            $dest = Join-Path $ctx.BackupDir $rel
            $destDir = Split-Path $dest -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Copy-Item -LiteralPath $src -Destination $dest -Force
        }
        # capture original file timestamps before overwriting
        $origTimes = $null
        try {
            $origItem = Get-Item -LiteralPath $src -Force
            $origTimes = @{ c = $origItem.CreationTime; w = $origItem.LastWriteTime; a = $origItem.LastAccessTime }
        } catch { }
        Copy-Item -LiteralPath $tmp -Destination $finalPath -Force
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        # restore original timestamps (copy resets Created date otherwise)
        if ($origTimes) {
            try {
                $newItem = Get-Item -LiteralPath $finalPath -Force
                $newItem.CreationTime   = $origTimes.c
                $newItem.LastWriteTime  = $origTimes.w
                $newItem.LastAccessTime = $origTimes.a
            } catch { }
        }
        # remove the original when the extension changed
        if ($finalPath -ne $src) {
            Remove-Item -LiteralPath $src -Force
        }

        return [pscustomobject]@{
            path = $finalPath; kind = $item.Kind; before = $sizeBefore; after = $sizeAfter
            saved_pct = [math]::Round($savingPct, 1); tool = $tool; seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
            status = 'ok'
        }

    } catch {
        if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        return [pscustomobject]@{
            path = $src; kind = $item.Kind; before = $sizeBefore; after = $sizeBefore
            saved_pct = 0; tool = ''; seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
            status = "fail: $($_.Exception.Message)"
        }
    } finally {
        Update-Active $null
        try {
            if ($state.Prog.ContainsKey($src)) {
                $pf = $state.Prog[$src]
                $state.Prog.Remove($src)
                Remove-Item -LiteralPath $pf.File -Force -ErrorAction SilentlyContinue
            }
        } catch { }
        $watch.Stop()
    }
}

# shared state (thread-safe)
$state = [hashtable]::Synchronized(@{
    Active = [hashtable]::Synchronized(@{})
    Prog = [hashtable]::Synchronized(@{})
})

$ctx = @{
    FFMPEG = $FFMPEG; FFPROBE = $FFPROBE
    OXIPNG = $OXIPNG; PNGQUANT = $PNGQUANT
    JPEGTOOL = $JPEGTOOL; JPEGKIND = $JPEGKIND
    TempDir = $script:TempDir; BackupDir = $script:BackupDir
    Backup = [bool]$Backup; MinSaving = $MinSaving
    useGpu = $useGpu; encoder = $encoder; Codec = $Codec
    cq = $P.cq; nvPreset = $P.nvPreset; cpuCrf = $P.cpuCrf; cpuPreset = $P.cpuPreset
    jpgQ = $P.jpgQ; pngQ = $P.pngQ
    Mp4AudioCodecs = $script:Mp4AudioCodecs
    TargetCodecName = $Codec
}

# ============================================================ runspace pools
$pools = @()
$pending = New-Object System.Collections.Generic.List[object]

function Queue-Work([array]$queue, [int]$maxWorkers, [string]$poolName) {
    if ($queue.Count -eq 0) { return }
    $pool = [runspacefactory]::CreateRunspacePool(1, $maxWorkers)
    $pool.ApartmentState = 'MTA'
    $pool.Open()
    $script:pools += $pool
    foreach ($item in $queue) {
        $ps = [powershell]::Create().AddScript($workerScript).AddArgument($item).AddArgument($ctx).AddArgument($state)
        $ps.RunspacePool = $pool
        $pending.Add(@{ PS = $ps; Async = $ps.BeginInvoke(); Item = $item })
    }
}

try {
    Queue-Work $vidQueue $VideoWorkers 'video'
    Queue-Work $imgQueue $ImageWorkers 'image'

    # ============================================================ progress UI
    # A single-line live progress bar, OVERWRITTEN in place with \r. State
    # variables live in $script: scope so they persist across calls (plain
    # assignments inside a function would create throwaway locals).
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $totalWork = $pending.Count
    $totalWorkBytes = (($vidQueue + $imgQueue) | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
    $results = New-Object System.Collections.Generic.List[object]
    $doneCount = 0; $doneBytes = 0; $savedBytes = 0; $failCount = 0

    $script:lastLine = ''
    $script:lastTick = -1

    function Clip-Text([string]$s) {
        if ($null -eq $s) { return '' }
        $w = try { [Math]::Max(30, [Console]::WindowWidth - 1) } catch { 120 }
        if ($s.Length -gt $w) { $s = $s.Substring(0, $w - 1) + '~' }
        return $s
    }

    # Read ffmpeg's live -progress output and return the encode percentage,
    # or -1 when nothing usable has been written yet.
    function Get-ProgPercent([hashtable]$entry) {
        try {
            if (-not (Test-Path -LiteralPath $entry.File)) { return -1 }
            $lines = @(Get-Content -LiteralPath $entry.File -Tail 40 -ErrorAction Stop)
            $micro = $null
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                if ($lines[$i] -match '^out_time_us=(\d+)') { $micro = [double]$Matches[1]; break }
                if ($lines[$i] -match '^out_time_ms=(\d+)') { $micro = [double]$Matches[1]; break }
            }
            if ($null -eq $micro -or $entry.Dur -le 0) { return -1 }
            $pct = [int][math]::Floor(($micro / 1000000.0) / $entry.Dur * 100)
            return [math]::Max(0, [math]::Min(100, $pct))
        } catch { return -1 }
    }

    function Render-Status([bool]$force = $false) {
        $pct    = if ($totalWork -gt 0) { ($doneCount / $totalWork) * 100 } else { 100 }
        $barLen = 24
        $filled = [math]::Floor($barLen * $pct / 100)
        $bar    = ('#' * $filled).PadRight($barLen, '-')
        $eta    = if ($doneBytes -gt 0) { ($stopwatch.Elapsed.TotalSeconds / $doneBytes) * ($totalWorkBytes - $doneBytes) } else { 0 }
        $savedP = if ($totalBytesBefore -gt 0) { ($savedBytes / $totalBytesBefore) * 100 } else { 0 }

        $activeKeys = @()
        [System.Threading.Monitor]::Enter($state.SyncRoot)
        try { $activeKeys = @($state.Active.Keys) } finally { [System.Threading.Monitor]::Exit($state.SyncRoot) }
        $labels = @()
        foreach ($k in $activeKeys) {
            $lbl = [string]$state.Active[$k]
            if ($state.Prog.ContainsKey($k)) {
                $pp = Get-ProgPercent $state.Prog[$k]
                if ($pp -ge 0) { $lbl = "{0} {1}%" -f $lbl, $pp }
            }
            $labels += $lbl
        }
        $labels = @($labels | Sort-Object)
        $working = if ($labels.Count) { ($labels -join ', ') } else { 'idle' }
        if ($working.Length -gt 70) { $working = $working.Substring(0, 67) + '...' }

        $line = Clip-Text ("  [{0}] {1,5:N1}%  |  {2}/{3} files  |  saved {4} ({5:N0}%)  |  ETA {6}  |  now: {7}" -f
            $bar, $pct, $doneCount, $totalWork, (Format-Size $savedBytes), $savedP, (Format-Duration $eta), $working)

        # skip redraw when nothing changed (except the forced final render)
        $changed = $line -ne $script:lastLine
        if ($changed) { $script:lastLine = $line }

        if ([Console]::IsOutputRedirected) {
            # cannot overwrite lines when output is redirected: print at most
            # one line per second, and never repeat an identical line
            if (-not $changed) { return }
            $tick = [int]$stopwatch.Elapsed.TotalSeconds
            if (-not $force) {
                if ($tick -le $script:lastTick) { return }
                $script:lastTick = $tick
            }
            [Console]::Out.WriteLine($line)
            return
        }

        try {
            $w = [Math]::Max(0, [Console]::WindowWidth - 1)
            [Console]::Out.Write("`r" + $line.PadRight($w))
        } catch {
            [Console]::Out.Write("`r" + $line)
        }
        if ($force) { [Console]::Out.Write("`n") }
    }

    while ($pending.Count -gt 0) {
        for ($i = $pending.Count - 1; $i -ge 0; $i--) {
            $h = $pending[$i]
            if ($h.Async.IsCompleted) {
                $pending.RemoveAt($i)
                try {
                    $rOut = @($h.PS.EndInvoke($h.Async))
                    $r = $rOut | Select-Object -Last 1
                    if ($r) {
                        $results.Add($r)
                        $doneCount++
                        $doneBytes += $r.before
                        if ($r.status -eq 'ok') {
                            $savedBytes += ($r.before - $r.after)
                        } elseif ($r.status -like 'fail*') {
                            $failCount++
                        }
                    }
                } catch {
                    $failCount++
                    $doneCount++
                    $results.Add([pscustomobject]@{
                        path = $h.Item.File.FullName; kind = $h.Item.Kind; before = $h.Item.File.Length; after = $h.Item.File.Length
                        saved_pct = 0; tool = ''; seconds = 0; status = "fail: $($_.Exception.Message)"
                    })
                } finally {
                    $h.PS.Dispose()
                }
            }
        }
        Render-Status
        if ($pending.Count -gt 0) { Start-Sleep -Milliseconds 250 }
    }
    Render-Status $true
    $stopwatch.Stop()
} finally {
    foreach ($p in $pools) { $p.Close(); $p.Dispose() }
    [Console]::Title = "Optimize-Media - done"
}

# ============================================================ report
$reportFile = Join-Path $script:LogDir ("report-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".csv")
if ($results.Count -gt 0) {
    $results | Export-Csv -LiteralPath $reportFile -NoTypeInformation -Encoding UTF8
    $okRows = $results | Where-Object { $_.status -eq 'ok' } | Select-Object @{n='path';e={$_.path}}, @{n='date';e={(Get-Date).ToString('s')}}
    if ($okRows) {
        $okRows | Export-Csv -LiteralPath $historyPath -NoTypeInformation -Encoding UTF8 -Append
    }
}

Write-Host "`n==================================================" -ForegroundColor Magenta
Write-Host "  RESULTS" -ForegroundColor Magenta
Write-Host "==================================================" -ForegroundColor Magenta

$okRes   = @($results | Where-Object { $_.status -eq 'ok' })
$skipRes = @($results | Where-Object { $_.status -eq 'skipped-small-gain' })
$unsafeRes = @($results | Where-Object { $_.status -like 'skip:*' })
$failRes = @($results | Where-Object { $_.status -like 'fail*' })

Write-Host ("  Compressed : {0} files" -f $okRes.Count)
Write-Host ("  Skipped    : {0} files ({1} small-gain, {2} already done earlier)" -f ($skipRes.Count + $preSkipped), $skipRes.Count, $preSkipped)
if ($unsafeRes.Count -gt 0) {
    Write-Host ("  Left as-is : {0} files (conversion would lose streams)" -f $unsafeRes.Count) -ForegroundColor Yellow
    $unsafeRes | Select-Object -First 8 | ForEach-Object {
        Write-Host ("    - {0}: {1}" -f $_.path.Split('\')[-1], ($_.status -replace '^skip: ', '')) -ForegroundColor Yellow
    }
    if ($unsafeRes.Count -gt 8) { Write-Info ("    ... and {0} more" -f ($unsafeRes.Count - 8)) }
}
if ($failRes.Count -gt 0) {
    Write-Host ("  Failed     : {0} files" -f $failRes.Count) -ForegroundColor Red
    $failRes | Select-Object -First 5 | ForEach-Object { Write-Host ("    - {0}: {1}" -f $_.path.Split('\')[-1], $_.status) -ForegroundColor Red }
}
Write-Host ""
$after  = $totalBytesBefore - $savedBytes
$overall= if ($totalBytesBefore -gt 0) { ($savedBytes / $totalBytesBefore) * 100 } else { 0 }
Write-Host ("  Before     : {0}" -f (Format-Size $totalBytesBefore))
Write-Host ("  After      : {0}" -f (Format-Size $after))
Write-Host ("  Saved      : {0}  ({1:N1}%)" -f (Format-Size $savedBytes), $overall) -ForegroundColor Green

$bestSize = $okRes | Sort-Object { $_.before - $_.after } -Descending | Select-Object -First 1
$bestPct  = $okRes | Sort-Object saved_pct -Descending | Select-Object -First 1
if ($bestSize) {
    Write-Host ("  Best size  : {0}  (-{1})" -f $bestSize.path.Split('\')[-1], (Format-Size ($bestSize.before - $bestSize.after)))
}
if ($bestPct) {
    Write-Host ("  Best %     : {0}  (-{1:N1}%)" -f $bestPct.path.Split('\')[-1], $bestPct.saved_pct)
}
Write-Host ("  Time       : {0}" -f (Format-Duration $stopwatch.Elapsed.TotalSeconds))

foreach ($k in @('image', 'video')) {
    $rows = @($okRes | Where-Object { $_.kind -eq $k })
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

# Alert the user the job is done, even if the window is in the background.
Show-FinishedNotification -Title "Optimize-Media finished" -Body ("{0} files done, saved {1} ({2:N0}%) in {3}" -f $okRes.Count, (Format-Size $savedBytes), $overall, (Format-Duration $stopwatch.Elapsed.TotalSeconds))

# keep the window open when launched by double-click
if ($Host.Name -eq 'ConsoleHost' -and -not $env:OM_IGNORE_PAUSE) {
    Write-Host "`nPress Enter to close..." -ForegroundColor Yellow
    Read-Host | Out-Null
}
