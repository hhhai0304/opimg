<#
.SYNOPSIS
    Watch-Progress - read-only live monitor for a running Optimize-Media job.
.DESCRIPTION
    Run this in a second terminal while Optimize-Media.ps1 is still going in
    its own window. It only READS the repo's temp/ folder (never writes, never
    touches the run) and reports how many files finished, how many encodes are
    active, ffmpeg/GPU activity and the temp footprint - a safe way to follow
    progress when the run's own status block cannot be watched.
    Ctrl+C stops the monitor.
.EXAMPLE
    .\Watch-Progress.ps1
    .\Watch-Progress.ps1 -Total 663        # show % and ETA (use the run's scan line total)
#>
[CmdletBinding()]
param(
    # repo folder whose temp/ holds the live run (default: this script's folder)
    [string]$Root,
    # total files of the run (from the "Scanned: N files" line of the run)
    [int]$Total = 0,
    [int]$PollMs = 1000
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$tempDir = Join-Path $Root 'temp'
if (-not (Test-Path -LiteralPath $tempDir)) {
    Write-Host "temp folder not found: $tempDir" -ForegroundColor Red
    Write-Host "Pass -Root pointing at the repo where Optimize-Media.ps1 runs." -ForegroundColor Red
    exit 1
}

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

# the live Optimize-Media process, if any (read-only query)
$runProcs = @()
try {
    $runProcs = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'Optimize-Media\.ps1' })
} catch { }

# temp files already present at start are in-flight, NOT counted as done
$seen = @{}
Get-ChildItem -LiteralPath $tempDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(vid_|img_)' } | ForEach-Object { $seen[$_.Name] = $true }
$inFlight0 = $seen.Count
$started = 0

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastLine = ''
$nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue
$logical = try { [int](Get-CimInstance Win32_Processor).NumberOfLogicalProcessors } catch { 1 }
$lastFfCpu = $null
$lastFfWall = -1.0
$wasAlive = ($runProcs.Count -gt 0)

Write-Host "Watching $tempDir (read-only - temp files are never touched). Ctrl+C to stop." -ForegroundColor Cyan
if ($runProcs.Count -eq 0) {
    Write-Host "No running Optimize-Media process found - the job may have just finished." -ForegroundColor Yellow
}

while ($true) {
    Start-Sleep -Milliseconds $PollMs
    $wallS = [math]::Max(0.001, $sw.Elapsed.TotalSeconds)

    $files = @(Get-ChildItem -LiteralPath $tempDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(vid_|img_)' })
    $inFlight = $files.Count
    foreach ($f in $files) {
        if (-not $seen.ContainsKey($f.Name)) { $seen[$f.Name] = $true; $started++ }
    }
    # one temp file is created per task; a task is done when its temp file is
    # gone, so: done = creations since start + in-flight at start - in-flight now
    $done = [math]::Max(0, $started + $inFlight0 - $inFlight)

    $tempBytes = ($files | Measure-Object Length -Sum).Sum

    $ff = @(Get-Process -Name ffmpeg -ErrorAction SilentlyContinue)
    $ffCpuT = ($ff | Measure-Object CPU -Sum).Sum
    $ffCpuPct = 0
    if ($null -ne $lastFfCpu -and $wallS -gt $lastFfWall) {
        $ffCpuPct = [math]::Max(0, (($ffCpuT - $lastFfCpu) / ($wallS - $lastFfWall)) / $logical * 100)
    }
    $lastFfCpu = $ffCpuT
    $lastFfWall = $wallS

    $gpuTxt = ''
    if ($nvidia) {
        try {
            $g = @(& $nvidia.Source --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2>$null)
            if ($g.Count -gt 0) { $gpuTxt = $g[0].Trim() }
        } catch { }
    }

    $runAlive = $false
    foreach ($p in $runProcs) {
        if (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue) { $runAlive = $true; break }
    }

    if ($wasAlive -and -not $runAlive) {
        Write-Host "`nOptimize-Media run has finished." -ForegroundColor Green
        exit 0
    }
    $wasAlive = $runAlive

    $parts = @()
    if ($Total -gt 0) {
        $pct = $done / $Total * 100
        $etaS = if ($done -gt 0) { ($Total - $done) / ($done / $wallS) } else { 0 }
        $parts += ("files {0}/{1} ({2:N1}%)" -f $done, $Total, $pct)
        $parts += ("ETA {0}" -f (Format-Duration $etaS))
    } else {
        $parts += ("files {0} done" -f $done)
    }
    $parts += ("active {0}" -f $inFlight)
    $parts += ("temp {0}" -f (Format-Size $tempBytes))
    if ($ff.Count -gt 0) { $parts += ("ffmpeg {0} ({1:N0}%)" -f $ff.Count, $ffCpuPct) }
    if ($gpuTxt) { $parts += ("GPU {0}" -f $gpuTxt) }
    $line = ("  {0}  |  elapsed {1}  |  run status: {2}" -f ($parts -join '  |  '), (Format-Duration $wallS), $(if ($runAlive) { 'running' } else { 'not found' }))

    if ($line -eq $lastLine) { continue }
    $lastLine = $line
    if ([Console]::IsOutputRedirected) {
        [Console]::Out.WriteLine($line)
    } else {
        $w = try { [Console]::WindowWidth } catch { 120 }
        [Console]::Out.Write("`r" + $line.PadRight([math]::Max(0, $w - 1)))
    }
}