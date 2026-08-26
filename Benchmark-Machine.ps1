#requires -Version 5.1
<#
.SYNOPSIS
    Benchmarks this machine and writes performance defaults into config.json.
    Existing user-tuned values are preserved unless -Force is used.
.DESCRIPTION
    Works on Windows, Linux and macOS (pwsh 7+ on Unix). Detects CPU/RAM/GPU
    per OS, measures concurrent NVENC sessions with ffmpeg, and prints an AV1
    preference suggestion when the GPU supports it. The default video codec of
    Optimize-Media stays H.265/HEVC - enabling AV1 is a manual config choice.
#>
[CmdletBinding()]
param([switch]$Force)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RootDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:RootDir 'config.json'

# OS detection: Windows PowerShell 5.1 has no $IsWindows variables at all
$osName = if ($PSVersionTable.PSVersion.Major -ge 6) {
    if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
} else { 'windows' }

if (-not (Test-Path $script:ConfigPath)) {
    Write-Host "config.json not found - run setup.ps1 first." -ForegroundColor Red
    exit 1
}
$cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json

Write-Host "`n==> Benchmarking this machine ($osName)" -ForegroundColor Cyan

# ---- CPU / RAM ----
$cpuName = '(unknown)'
$cores = 0; $logical = 0; $ramGB = 0.0
switch ($osName) {
    'windows' {
        $cpu = Get-CimInstance Win32_Processor
        $os  = Get-CimInstance Win32_OperatingSystem
        $cpuName = [string]$cpu.Name
        $cores   = [int]$cpu.NumberOfCores
        $logical = [int]$cpu.NumberOfLogicalProcessors
        $ramGB   = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    }
    'linux' {
        try { $cpuName = ((Get-Content '/proc/cpuinfo' | Where-Object { $_ -match '^model name' }) -replace '^.*:\s*', '' | Select-Object -First 1) } catch { }
        if (-not $cpuName) { try { $cpuName = (lscpu | Where-Object { $_ -match '^Model name' }) -replace '^.*:\s*', '' } catch { } }
        $logical = try { [int](nproc) } catch { 2 }
        try {
            $lscpuOut = lscpu
            $perCore = [int]($lscpuOut | Where-Object { $_ -match '^Core\(s\) per socket' } | ForEach-Object { ($_ -split ':')[-1].Trim() })
            $sockets = [int]($lscpuOut | Where-Object { $_ -match '^Socket\(s\)' } | ForEach-Object { ($_ -split ':')[-1].Trim() })
            $cores = $perCore * $sockets
        } catch { $cores = $logical }
        if ($cores -le 0) { $cores = $logical }
        $ramKB = try { [int64]((Get-Content '/proc/meminfo') -match '^MemTotal' -replace '^.*:\s*','' -replace '\skB','') } catch { 0 }
        $ramGB = [math]::Round($ramKB / 1MB, 1)
    }
    'macos' {
        $cpuName = try { [string](sysctl -n machdep.cpu.brand_string) } catch { '(unknown)' }
        $cores   = try { [int](sysctl -n hw.physicalcpu) } catch { 0 }
        $logical = try { [int](sysctl -n hw.ncpu) } catch { 0 }
        if ($cores -le 0) { $cores = $logical }
        $ramBytes = try { [int64](sysctl -n hw.memsize) } catch { 0 }
        $ramGB = [math]::Round($ramBytes / 1GB, 1)
    }
}
if ($logical -le 0) { $logical = if ($cores -gt 0) { $cores } else { 2 } }
Write-Host "  CPU    : $cpuName"
Write-Host "  Cores  : $cores physical / $logical logical"
Write-Host "  RAM    : $ramGB GB"

# ---- GPU name (informational; NVENC capability is decided by the real test below) ----
$gpuName = '(no NVIDIA GPU)'
switch ($osName) {
    'windows' {
        try {
            $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
            if ($gpu) { $gpuName = [string]$gpu.Name }
        } catch { }
    }
    'linux' {
        try {
            $smi = & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1
            if ($smi) { $gpuName = [string]$smi }
            else { $pci = (& lspci 2>$null | Where-Object { $_ -match 'NVIDIA' } | Select-Object -First 1); if ($pci) { $gpuName = (($pci -split ':', 2)[-1] -split '\(')[0].Trim() } }
        } catch { }
    }
    'macos' {
        # Apple Silicon / AMD GPUs have no NVENC; report the chipset for context
        try {
            $sp = (system_profiler SPDisplaysDataType 2>$null | Out-String)
            if ($sp -match 'Chipset Model:\s*(.+)') { $gpuName = $Matches[1].Trim() }
        } catch { }
    }
}
if ($gpuName -ne '(no NVIDIA GPU)') { Write-Host "  GPU    : $gpuName" }

# ---- Concurrent NVENC sessions (real test, identical everywhere ffmpeg runs) ----
$nvencSessions = 0
if ($cfg.gpu.nvenc -and $cfg.tools.ffmpeg) {
    Write-Host "  Testing concurrent NVENC sessions..." -NoNewline
    $ff = [string]$cfg.tools.ffmpeg
    $spawnArgs = @{
        FilePath  = $ff
        ArgumentList = '-y','-hide_banner','-loglevel','error','-f','lavfi','-i','color=black:s=1920x1080:d=2:r=30','-c:v','hevc_nvenc','-preset','p6','-cq','25','-f','null','-'
        PassThru  = $true
    }
    if ($osName -eq 'windows') { $spawnArgs.WindowStyle = 'Hidden' }
    $procs = 1..4 | ForEach-Object { Start-Process @spawnArgs }
    $procs | Wait-Process -Timeout 60 -ErrorAction SilentlyContinue
    $nvencSessions = @($procs | Where-Object { $_.ExitCode -eq 0 }).Count
    $procs | Where-Object { -not $_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host " $nvencSessions/4 OK"
}

# ---- Compute defaults ----
# Images: single-threaded tools per file -> use nearly all logical cores;
# extra workers also pipeline network I/O when sources are remote.
$imageWorkers = [math]::Max(2, [int][math]::Ceiling($logical * 0.9))
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

# ---- Codec preference suggestion (report only - default stays H.265/HEVC) ----
if ([bool]$cfg.gpu.av1_nvenc) {
    Write-Host "`n  Suggestion: this GPU supports AV1 encoding (~15-25% smaller than HEVC)." -ForegroundColor Yellow
    Write-Host "  To prefer AV1 for every run, add this to config.json:" -ForegroundColor Yellow
    Write-Host '      "codec": "av1"' -ForegroundColor Yellow
    Write-Host "  Default remains H.265/HEVC until you change it (per-run override: -Codec/-AV1)." -ForegroundColor Yellow
}
