#requires -Version 5.1
<#
.SYNOPSIS
    Benchmarks this machine and writes performance defaults into config.json.
    Existing user-tuned values are preserved unless -Force is used.
#>
[CmdletBinding()]
param([switch]$Force)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RootDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:RootDir 'config.json'

if (-not (Test-Path $script:ConfigPath)) {
    Write-Host "config.json not found - run setup.ps1 first." -ForegroundColor Red
    exit 1
}
$cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json

Write-Host "`n==> Benchmarking this machine" -ForegroundColor Cyan

# ---- CPU / RAM ----
$cpu = Get-CimInstance Win32_Processor
$os  = Get-CimInstance Win32_OperatingSystem
$cores   = [int]$cpu.NumberOfCores
$logical = [int]$cpu.NumberOfLogicalProcessors
$ramGB   = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
Write-Host "  CPU    : $($cpu.Name)"
Write-Host "  Cores  : $cores physical / $logical logical"
Write-Host "  RAM    : $ramGB GB"

# ---- Concurrent NVENC sessions (real test) ----
$nvencSessions = 0
if ($cfg.gpu.nvenc -and $cfg.tools.ffmpeg) {
    Write-Host "  Testing concurrent NVENC sessions..." -NoNewline
    $ff = [string]$cfg.tools.ffmpeg
    $procs = 1..4 | ForEach-Object {
        Start-Process -FilePath $ff -ArgumentList '-y','-hide_banner','-loglevel','error','-f','lavfi','-i','color=black:s=1920x1080:d=2:r=30','-c:v','hevc_nvenc','-preset','p6','-cq','25','-f','null','-' -PassThru -WindowStyle Hidden
    }
    $procs | Wait-Process -Timeout 60 -ErrorAction SilentlyContinue
    $nvencSessions = @($procs | Where-Object { $_.ExitCode -eq 0 }).Count
    $procs | Where-Object { -not $_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host " $nvencSessions/4 OK"
}

# ---- Compute defaults ----
# Images: CPU-bound, leave headroom. E-cores handle these fine.
$imageWorkers = [math]::Max(2, [math]::Min($logical - 4, 12))
# Videos: limited by NVENC sessions (GPU) or 2 for CPU encoding (CPU is also used by image workers)
$videoWorkers = if ($nvencSessions -ge 2) { [math]::Min($nvencSessions, 3) } elseif ($cfg.gpu.nvenc) { 1 } else { 2 }

$defaults = @{
    imageWorkers = $imageWorkers
    videoWorkers = $videoWorkers
    cpuCores     = $cores
    logicalCores = $logical
    ramGB        = $ramGB
    nvencSessions = $nvencSessions
    measuredAt   = (Get-Date).ToString('s')
}

# Preserve user tuning: only fill missing keys unless -Force
$existing = @{}
$perfProp = $cfg.PSObject.Properties['performance']
if ($perfProp -and -not $Force) {
    $perfProp.Value.PSObject.Properties | ForEach-Object { $existing[$_.Name] = $_.Value }
}
$merged = @{}
foreach ($k in $defaults.Keys) {
    if ($existing.ContainsKey($k) -and $existing[$k]) { $merged[$k] = $existing[$k] } else { $merged[$k] = $defaults[$k] }
}

# Write back (ConvertFrom-Json -> PSCustomObject; rebuild to keep it simple)
$cfg | Add-Member -NotePropertyName performance -NotePropertyValue ([pscustomobject]$merged) -Force
$cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8

Write-Host "`n  Performance defaults (edit config.json to tune):" -ForegroundColor Green
Write-Host "    imageWorkers  = $($merged.imageWorkers)   (parallel image compressions)"
Write-Host "    videoWorkers  = $($merged.videoWorkers)   (parallel video encodes)"
Write-Host "  Saved to: $script:ConfigPath"
