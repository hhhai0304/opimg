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

Write-Host "==================================================" -ForegroundColor Magenta
Write-Host "  Optimize-Media  |  preset: $Preset  |  video: $Codec ($encoder$(if($useGpu){' [GPU]'}))" -ForegroundColor Magenta
Write-Host "  Workers: $ImageWorkers images + $VideoWorkers videos (parallel)" -ForegroundColor Magenta
Write-Host "==================================================" -ForegroundColor Magenta

# ============================================================ collect files
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

    try {
        Update-Active $item.File.Name

        if ($item.Kind -eq 'image') {
            $tmp = Join-Path $ctx.TempDir ("img_" + [guid]::NewGuid().ToString('N') + $ext)
            Copy-Item -LiteralPath $src -Destination $tmp -Force
            $tool = 'none'

            switch -Regex ($ext) {
                '\.jpe?g$' {
                    if ($ctx.JPEGTOOL -and $ctx.JPEGKIND -eq 'jpegoptim') {
                        & $ctx.JPEGTOOL --strip-all --all-progressive $tmp 2>&1 | Out-Null
                        $tool = 'jpegoptim-lossless'
                    } elseif ($ctx.JPEGTOOL) {
                        $tmpOut = "$tmp.out.jpg"
                        & $ctx.JPEGTOOL -quality $ctx.jpgQ -optimize -progressive -outfile $tmpOut $tmp 2>&1 | Out-Null
                        if (Test-Path $tmpOut) { Move-Item $tmpOut $tmp -Force }
                        $tool = "mozjpeg-q$($ctx.jpgQ)"
                    } else {
                        $tmpOut = "$tmp.out.jpg"
                        & $ctx.FFMPEG -y -v error -i $tmp -c:v mjpeg -q:v 2 -map_metadata -1 $tmpOut 2>&1 | Out-Null
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
                        & $ctx.PNGQUANT --quality=$($ctx.pngQ) --speed 1 --strip --force --output $tmpQ $tmp 2>&1 | Out-Null
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
                    & $ctx.FFMPEG -y -v error -i $tmp -map_metadata -1 $tmpOut 2>&1 | Out-Null
                    if ((Test-Path $tmpOut) -and ((Get-Item $tmpOut).Length -lt (Get-Item $tmp).Length)) { Move-Item $tmpOut $tmp -Force }
                    $tool = 'ffmpeg-gif'
                }
                '\.webp$' {
                    $tmpOut = "$tmp.out.webp"
                    & $ctx.FFMPEG -y -v error -i $tmp -c:v libwebp -quality 85 -map_metadata -1 $tmpOut 2>&1 | Out-Null
                    if ((Test-Path $tmpOut) -and ((Get-Item $tmpOut).Length -lt (Get-Item $tmp).Length)) { Move-Item $tmpOut $tmp -Force }
                    $tool = 'libwebp-q85'
                }
                default {
                    $tmpOut = "$tmp.out$ext"
                    & $ctx.FFMPEG -y -v error -i $tmp -map_metadata -1 $tmpOut 2>&1 | Out-Null
                    if ((Test-Path $tmpOut) -and ((Get-Item $tmpOut).Length -lt (Get-Item $tmp).Length)) { Move-Item $tmpOut $tmp -Force }
                    $tool = 'ffmpeg'
                }
            }

            if (-not (Test-MediaValid $tmp)) { throw 'output is unreadable' }

        } else {
            # -------- video --------
            $tmp = Join-Path $ctx.TempDir ("vid_" + [guid]::NewGuid().ToString('N') + '.mp4')
            $durBefore = Get-VideoDuration $src

            $encArgs = @()
            if ($ctx.useGpu) {
                $encArgs = @('-c:v', $ctx.encoder, '-preset', $ctx.nvPreset, '-cq', $ctx.cq, '-rc', 'constqp')
                if ($ctx.Codec -eq 'av1') { $encArgs = @('-c:v', $ctx.encoder, '-preset', $ctx.nvPreset, '-cq', $ctx.cq) }
            } else {
                $encArgs = @('-c:v', $ctx.encoder, '-crf', $ctx.cpuCrf, '-preset', $ctx.cpuPreset)
                if ($ctx.Codec -eq 'hevc') { $encArgs += @('-tag:v', 'hvc1') }
            }
            $tool = "$($ctx.encoder) cq$($ctx.cq)" + $(if ($ctx.useGpu) { ' [GPU]' } else { ' [CPU]' })

            $argsList = @('-y', '-v', 'error', '-i', $src) + $encArgs + @('-c:a', 'copy', '-c:s', 'copy', '-map_metadata', '-1', '-movflags', '+faststart', $tmp)
            & $ctx.FFMPEG @argsList 2>&1 | Out-Null

            if (-not (Test-Path $tmp)) { throw 'ffmpeg did not produce an output' }
            if (-not (Test-MediaValid $tmp)) { throw 'output failed to decode' }
            $durAfter = Get-VideoDuration $tmp
            if ($durBefore -gt 0 -and $durAfter -gt 0 -and [math]::Abs($durAfter - $durBefore) -gt 1.0) {
                throw "duration mismatch ($durBefore vs $durAfter)"
            }
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

        # backup + replace
        if ($ctx.Backup) {
            $rel = $src
            if ($src.StartsWith($ctx.ScanRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $rel = $src.Substring($ctx.ScanRoot.Length).TrimStart('\', '/')
            }
            $dest = Join-Path $ctx.BackupDir $rel
            $destDir = Split-Path $dest -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Copy-Item -LiteralPath $src -Destination $dest -Force
        }
        Copy-Item -LiteralPath $tmp -Destination $src -Force
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue

        return [pscustomobject]@{
            path = $src; kind = $item.Kind; before = $sizeBefore; after = $sizeAfter
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
        $watch.Stop()
    }
}

# shared state (thread-safe)
$state = [hashtable]::Synchronized(@{
    Active = [hashtable]::Synchronized(@{})
})

$ctx = @{
    FFMPEG = $FFMPEG; FFPROBE = $FFPROBE
    OXIPNG = $OXIPNG; PNGQUANT = $PNGQUANT
    JPEGTOOL = $JPEGTOOL; JPEGKIND = $JPEGKIND
    TempDir = $script:TempDir; BackupDir = $script:BackupDir
    Backup = [bool]$Backup; MinSaving = $MinSaving; ScanRoot = $scanRoot
    useGpu = $useGpu; encoder = $encoder; Codec = $Codec
    cq = $P.cq; nvPreset = $P.nvPreset; cpuCrf = $P.cpuCrf; cpuPreset = $P.cpuPreset
    jpgQ = $P.jpgQ; pngQ = $P.pngQ
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
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $totalWork = $pending.Count
    $totalWorkBytes = (($vidQueue + $imgQueue) | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
    $results = New-Object System.Collections.Generic.List[object]
    $doneCount = 0; $doneBytes = 0; $savedBytes = 0; $failCount = 0
    $recent = New-Object 'System.Collections.Generic.Queue[string]'
    $useCursorUI = -not [Console]::IsOutputRedirected
    $statusTop = -1
    $statusLines = 3 + [math]::Max($VideoWorkers, 1)

    function Render-Status {
        $pct = if ($totalWork -gt 0) { ($doneCount / $totalWork) * 100 } else { 100 }
        $barLen = 24
        $filled = [math]::Floor($barLen * $pct / 100)
        $bar = ('#' * $filled).PadRight($barLen, '-')
        $eta = if ($doneBytes -gt 0) { ($stopwatch.Elapsed.TotalSeconds / $doneBytes) * ($totalWorkBytes - $doneBytes) } else { 0 }

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add(("[{0}] {1,5:N1}%  |  {2}/{3} files  |  saved {4}  |  ETA {5}   " -f $bar, $pct, $doneCount, $totalWork, (Format-Size $savedBytes), (Format-Duration $eta)))
        $activeSnapshot = @()
        [System.Threading.Monitor]::Enter($state.SyncRoot)
        try { $activeSnapshot = @($state.Active.Values | Select-Object -First ($statusLines - 3)) } finally { [System.Threading.Monitor]::Exit($state.SyncRoot) }
        foreach ($a in $activeSnapshot) { $lines.Add(("  working: {0}   " -f $a)) }
        for ($k = $activeSnapshot.Count; $k -lt ($statusLines - 3); $k++) { $lines.Add("") }
        $recentText = if ($recent.Count -gt 0) { "  recent: " + (($recent.ToArray() | Select-Object -Last 2) -join '  |  ') } else { "" }
        $lines.Add(($recentText + "   "))

        if ($useCursorUI) {
            try {
                $w = [math]::Max(0, [Console]::WindowWidth - 1)
                if ($statusTop -lt 0) {
                    foreach ($l in $lines) { [Console]::WriteLine($l.PadRight($w)) }
                    $statusTop = [Console]::CursorTop - $lines.Count
                } else {
                    [Console]::SetCursorPosition(0, $statusTop)
                    foreach ($l in $lines) { [Console]::WriteLine($l.PadRight($w)) }
                }
                [Console]::Title = ("Optimize-Media {0:N0}% ({1}/{2})" -f $pct, $doneCount, $totalWork)
            } catch {
                $script:useCursorUI = $false
                Write-Host $lines[0]
            }
        } else {
            Write-Host $lines[0]
        }
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
                            $recent.Enqueue(("{0} -{1:N0}%" -f $r.path.Split('\')[-1], $r.saved_pct))
                            while ($recent.Count -gt 4) { [void]$recent.Dequeue() }
                        } elseif ($r.status -like 'fail*') {
                            $failCount++
                            $recent.Enqueue(("FAILED: {0}" -f $r.path.Split('\')[-1]))
                            while ($recent.Count -gt 4) { [void]$recent.Dequeue() }
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
    $stopwatch.Stop()
} finally {
    foreach ($p in $pools) { $p.Close(); $p.Dispose() }
    if ($useCursorUI -and $statusTop -ge 0) { [Console]::SetCursorPosition(0, $statusTop + $statusLines) }
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
$failRes = @($results | Where-Object { $_.status -like 'fail*' })

Write-Host ("  Compressed : {0} files" -f $okRes.Count)
Write-Host ("  Skipped    : {0} files ({1} small-gain, {2} already done earlier)" -f ($skipRes.Count + $preSkipped), $skipRes.Count, $preSkipped)
if ($failRes.Count -gt 0) {
    Write-Host ("  Failed     : {0} files" -f $failRes.Count) -ForegroundColor Red
    $failRes | Select-Object -First 5 | ForEach-Object { Write-Host ("    - {0}: {1}" -f $_.path.Split('\')[-1], $_.status) -ForegroundColor Red }
}
Write-Host ("  Before     : {0}" -f (Format-Size $totalBytesBefore))
Write-Host ("  After      : {0}" -f (Format-Size ($totalBytesBefore - $savedBytes)))
Write-Host ("  Saved      : {0}  ({1:N1}%)" -f (Format-Size $savedBytes), $(if ($totalBytesBefore -gt 0) { ($savedBytes / $totalBytesBefore) * 100 } else { 0 })) -ForegroundColor Green
Write-Host ("  Time       : {0}  ({1:N0} MB/s processed)" -f (Format-Duration $stopwatch.Elapsed.TotalSeconds), $(if ($stopwatch.Elapsed.TotalSeconds -gt 0) { $doneBytes / 1MB / $stopwatch.Elapsed.TotalSeconds } else { 0 }))

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

# keep the window open when launched by double-click
if ($Host.Name -eq 'ConsoleHost' -and -not $env:OM_IGNORE_PAUSE) {
    Write-Host "`nPress Enter to close..." -ForegroundColor Yellow
    Read-Host | Out-Null
}
