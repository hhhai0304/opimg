#requires -Version 5.1
<#
.SYNOPSIS
    Installs all required tools for Optimize-Media (ffmpeg, oxipng, pngquant, JPEG optimizer).
.DESCRIPTION
    Run once per machine. Automatically:
      - Downloads portable binaries into .\tools\ (preferred - copy folder to another PC and go)
      - Reuses tools already on PATH when available
      - Detects NVIDIA NVENC to pick the optimal video encoder
      - Verifies each tool after install with a clear pass/fail report
.EXAMPLE
    .\setup.ps1
    .\setup.ps1 -Force   # re-download everything even if already present
#>
[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RootDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ToolsDir = Join-Path $script:RootDir 'tools'
$script:TempDir  = Join-Path $script:RootDir 'temp'
$script:LogDir   = Join-Path $script:RootDir 'logs'
$script:ConfigPath = Join-Path $script:RootDir 'config.json'

# ---------------------------------------------------------------- helpers
function Write-Step([string]$msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)    { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg)  { Write-Host "  [FAIL] $msg" -ForegroundColor Red }

function Test-ToolOnPath([string]$name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    return $(if ($cmd) { $cmd.Source } else { $null })
}

function Get-ToolInDir([string]$dir, [string]$exeName) {
    if (-not (Test-Path $dir)) { return $null }
    $hit = Get-ChildItem -LiteralPath $dir -Recurse -Filter $exeName -File -ErrorAction SilentlyContinue |
           Select-Object -First 1
    return $(if ($hit) { $hit.FullName } else { $null })
}

function Download-File([string]$url, [string]$outFile) {
    Write-Host "    Downloading: $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($url, $outFile)
}

function Expand-ZipTo([string]$zip, [string]$dest) {
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
}

function Test-NvencEncoder([string]$ffmpegPath, [string]$codec) {
    # NVENC requires a minimum frame size; use 1920x1080 to be safe
    & $ffmpegPath -hide_banner -loglevel error -f lavfi -i "color=black:s=1920x1080:d=0.1:r=30" -c:v $codec -f null - 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------- init
Write-Host "==============================================" -ForegroundColor Magenta
Write-Host "  Optimize-Media - Setup" -ForegroundColor Magenta
Write-Host "==============================================" -ForegroundColor Magenta

# OS detection: Windows PowerShell 5.1 has no $IsWindows variables at all
$osName = if ($PSVersionTable.PSVersion.Major -ge 6) {
    if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
} else { 'windows' }
Write-Host "Detected OS: $osName"

# preserve user preferences across setup re-runs
$prior = @{}
if (Test-Path $script:ConfigPath) {
    try {
        $old = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        $old.PSObject.Properties | Where-Object { $_.Name -notin @('tools', 'gpu', 'updated', 'performance') } |
            ForEach-Object { $prior[$_.Name] = $_.Value }
    } catch { }
}

foreach ($d in @($script:ToolsDir, $script:TempDir, $script:LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

$dlDir = Join-Path $script:TempDir 'dl'
if (-not (Test-Path $dlDir)) { New-Item -ItemType Directory -Path $dlDir | Out-Null }

$tools = @{}   # name -> @{ Path=...; Source='path'|'portable'|'winget'|'missing'; Kind=... }

# On Unix everything comes from the system package manager, so the four
# Windows download sections below are skipped entirely.
$usingPkgMgr = ($osName -ne 'windows')
if ($usingPkgMgr) {
    Write-Step "1-4/4  Installing tools via system package manager"
    $pkgs = @(); $pkg = $null
    if ($osName -eq 'macos') {
        $pkg = 'brew'; $pkgs = @('ffmpeg', 'oxipng', 'pngquant', 'jpegoptim', 'mozjpeg')
    } else {
        foreach ($cand in @('apt-get', 'dnf', 'pacman')) { if (Test-ToolOnPath $cand) { $pkg = $cand; break } }
        $pkgs = switch ($pkg) {
            'apt-get' { @('ffmpeg', 'oxipng', 'pngquant', 'jpegoptim') }
            'dnf'     { @('ffmpeg', 'oxipng', 'pngquant', 'jpegoptim') }
            'pacman'  { @('ffmpeg', 'oxipng', 'pngquant', 'jpegoptim') }
            default   { @() }
        }
    }
    if (-not $pkg -or $pkgs.Count -eq 0) {
        Write-Fail "No supported package manager found (brew/apt-get/dnf/pacman)."
        Write-Fail "Install manually: ffmpeg ffprobe oxipng pngquant jpegoptim, then re-run setup.ps1"
    } else {
        $sudo = @()
        if ($osName -ne 'macos' -and [int](& id -u) -ne 0 -and (Test-ToolOnPath 'sudo')) { $sudo = @('sudo') }
        Write-Host "    Installing $($pkgs -join ', ') via $pkg..."
        try {
            switch ($pkg) {
                'brew'    { & brew install @pkgs 2>&1 | Out-Null }
                'apt-get' { & @($sudo + $pkg + 'update') 2>&1 | Out-Null; & @($sudo + $pkg + 'install' + '-y' + $pkgs) 2>&1 | Out-Null }
                'dnf'     { & @($sudo + $pkg + 'install' + '-y' + $pkgs) 2>&1 | Out-Null }
                'pacman'  { & @($sudo + $pkg + '-S' + '--needed' + '--noconfirm' + $pkgs) 2>&1 | Out-Null }
            }
        } catch {
            Write-Fail "Package installation issue: $($_.Exception.Message)"
        }
        # resolve installed binaries (cjpeg/mozjpeg preferred, jpegoptim fallback)
        $cj = Test-ToolOnPath 'cjpeg'
        if ($cj) { $tools['cjpeg'] = @{ Path = $cj; Source = 'pkg' }; Write-Ok "cjpeg: $cj" }
        $jo = Test-ToolOnPath 'jpegoptim'
        if ($jo -and -not $tools.ContainsKey('cjpeg')) {
            $tools['cjpeg'] = @{ Path = $jo; Source = 'pkg'; Kind = 'jpegoptim' }
            Write-Ok "jpegoptim: $jo"
        }
        foreach ($t in @('ffmpeg', 'ffprobe', 'oxipng', 'pngquant')) {
            $hit = Test-ToolOnPath $t
            if ($hit) {
                $tools[$t] = @{ Path = $hit; Source = 'pkg' }
                Write-Ok "${t}: $hit"
            } else {
                $tools[$t] = @{ Path = $null; Source = 'missing' }
                Write-Fail "$t not found after install"
            }
        }
    }
}

if (-not $usingPkgMgr) {
# ============================================================ 1. ffmpeg + ffprobe
Write-Step "1/4  ffmpeg + ffprobe"
$ff = Test-ToolOnPath 'ffmpeg'
$fp = Test-ToolOnPath 'ffprobe'
if ($ff -and $fp -and -not $Force) {
    $tools['ffmpeg']  = @{ Path = $ff; Source = 'path' }
    $tools['ffprobe'] = @{ Path = $fp; Source = 'path' }
    Write-Ok "Already on PATH: $ff"
} else {
    $dest = Join-Path $script:ToolsDir 'ffmpeg'
    $existingF = Get-ToolInDir $dest 'ffmpeg.exe'
    $existingP = Get-ToolInDir $dest 'ffprobe.exe'
    if ($existingF -and $existingP -and -not $Force) {
        $tools['ffmpeg']  = @{ Path = $existingF; Source = 'portable' }
        $tools['ffprobe'] = @{ Path = $existingP; Source = 'portable' }
        Write-Ok "Already portable: $existingF"
    } else {
        try {
            # official essentials build from gyan.dev (includes NVENC)
            $url  = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
            $zip  = Join-Path $dlDir 'ffmpeg.zip'
            Download-File $url $zip
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            Expand-ZipTo $zip $dest
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            $f = Get-ToolInDir $dest 'ffmpeg.exe'
            $p = Get-ToolInDir $dest 'ffprobe.exe'
            if ($f -and $p) {
                $tools['ffmpeg']  = @{ Path = $f; Source = 'portable' }
                $tools['ffprobe'] = @{ Path = $p; Source = 'portable' }
                Write-Ok "ffmpeg portable: $f"
            } else { throw "ffmpeg.exe not found after extraction" }
        } catch {
            Write-Fail "ffmpeg: $($_.Exception.Message)"
            $tools['ffmpeg']  = @{ Path = $null; Source = 'missing' }
            $tools['ffprobe'] = @{ Path = $null; Source = 'missing' }
        }
    }
}

# ============================================================ 2. JPEG optimizer (jpegoptim / cjpeg)
Write-Step "2/4  JPEG optimizer (jpegoptim, lossless - safest option)"
$cj = Test-ToolOnPath 'cjpeg'
$jo = Test-ToolOnPath 'jpegoptim'
if ($cj -and -not $Force) {
    $tools['cjpeg'] = @{ Path = $cj.Source; Source = 'path' }
    Write-Ok "Already have cjpeg: $($cj.Source)"
} elseif ($jo -and -not $Force) {
    $tools['cjpeg'] = @{ Path = $jo.Source; Source = 'path'; Kind = 'jpegoptim' }
    Write-Ok "Already have jpegoptim: $($jo.Source)"
} else {
    $dest = Join-Path $script:ToolsDir 'mozjpeg'
    $existing = Get-ToolInDir $dest 'cjpeg.exe'
    if ($existing -and -not $Force) {
        $tools['cjpeg'] = @{ Path = $existing; Source = 'portable' }
        Write-Ok "Already portable: $existing"
    } else {
        try {
            $wg = Test-ToolOnPath 'winget'
            $installed = $false
            if ($wg) {
                Write-Host "    Installing jpegoptim via winget..."
                & $wg install --id TimoKokkonen.Jpegoptim -e --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
                # winget updates PATH but this session may not see it; check the default link
                $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\jpegoptim.exe'
                if (Test-Path $link) { $installed = $true; $tools['cjpeg'] = @{ Path = $link; Source = 'winget'; Kind = 'jpegoptim' }; Write-Ok "jpegoptim via winget: $link" }
                else {
                    $jo2 = Test-ToolOnPath 'jpegoptim'
                    if ($jo2) { $installed = $true; $tools['cjpeg'] = @{ Path = $jo2.Source; Source = 'winget'; Kind = 'jpegoptim' }; Write-Ok "jpegoptim via winget: $($jo2.Source)" }
                }
            }
            if (-not $installed) { throw "Could not install a JPEG optimizer automatically" }
        } catch {
            Write-Fail "JPEG optimizer: $($_.Exception.Message) -> JPEG will fall back to ffmpeg (still good, slightly less optimal)"
            $tools['cjpeg'] = @{ Path = $null; Source = 'missing' }
        }
    }
}

# ============================================================ 3. oxipng
Write-Step "3/4  oxipng - lossless PNG"
$ox = Test-ToolOnPath 'oxipng'
if ($ox -and -not $Force) {
    $tools['oxipng'] = @{ Path = $ox.Source; Source = 'path' }
    Write-Ok "Already on PATH: $($ox.Source)"
} else {
    $dest = Join-Path $script:ToolsDir 'oxipng'
    $existing = Get-ToolInDir $dest 'oxipng.exe'
    if ($existing -and -not $Force) {
        $tools['oxipng'] = @{ Path = $existing; Source = 'portable' }
        Write-Ok "Already portable: $existing"
    } else {
        try {
            $rel = Invoke-RestMethod 'https://api.github.com/repos/oxipng/oxipng/releases/latest'
            $asset = $rel.assets | Where-Object { $_.name -match 'x86_64-pc-windows-msvc\.zip$' } | Select-Object -First 1
            if (-not $asset) { throw "No Windows asset found in release" }
            $zip = Join-Path $dlDir 'oxipng.zip'
            Download-File $asset.browser_download_url $zip
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            Expand-ZipTo $zip $dest
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            $o = Get-ToolInDir $dest 'oxipng.exe'
            if ($o) {
                $tools['oxipng'] = @{ Path = $o; Source = 'portable' }
                Write-Ok "oxipng portable: $o"
            } else { throw "oxipng.exe not found after extraction" }
        } catch {
            Write-Fail "oxipng: $($_.Exception.Message)"
            $tools['oxipng'] = @{ Path = $null; Source = 'missing' }
        }
    }
}

# ============================================================ 4. pngquant
Write-Step "4/4  pngquant - light lossy PNG"
$pq = Test-ToolOnPath 'pngquant'
if ($pq -and -not $Force) {
    $tools['pngquant'] = @{ Path = $pq.Source; Source = 'path' }
    Write-Ok "Already on PATH: $($pq.Source)"
} else {
    $dest = Join-Path $script:ToolsDir 'pngquant'
    $existing = Get-ToolInDir $dest 'pngquant.exe'
    if ($existing -and -not $Force) {
        $tools['pngquant'] = @{ Path = $existing; Source = 'portable' }
        Write-Ok "Already portable: $existing"
    } else {
        try {
            # official link from pngquant.org
            $zip = Join-Path $dlDir 'pngquant.zip'
            Download-File 'https://pngquant.org/pngquant-windows.zip' $zip
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            Expand-ZipTo $zip $dest
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            $p = Get-ToolInDir $dest 'pngquant.exe'
            if ($p) {
                $tools['pngquant'] = @{ Path = $p; Source = 'portable' }
                Write-Ok "pngquant portable: $p"
            } else { throw "pngquant.exe not found after extraction" }
        } catch {
            Write-Fail "pngquant: $($_.Exception.Message) (lossy PNG will be skipped, lossless still works)"
            $tools['pngquant'] = @{ Path = $null; Source = 'missing' }
        }
    }
}
} # end Windows download sections

# ============================================================ GPU check
Write-Step "Checking NVIDIA GPU (NVENC)"
$hasNvenc = $false
$gpuName  = '(no NVIDIA GPU)'
try {
    switch ($osName) {
        'windows' {
            $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
            if ($gpu) { $gpuName = [string]$gpu.Name }
        }
        'linux' {
            $smi = & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1
            if ($smi) { $gpuName = [string]$smi }
            else {
                $pci = & lspci 2>$null | Where-Object { $_ -match 'NVIDIA' } | Select-Object -First 1
                if ($pci) { $gpuName = (($pci -split ':', 2)[-1] -split '\(')[0].Trim() }
            }
        }
        'macos' {
            # no NVIDIA drivers on modern macOS; report chipset for context
            $sp = (system_profiler SPDisplaysDataType 2>$null | Out-String)
            if ($sp -match 'Chipset Model:\s*(.+)') { $gpuName = $Matches[1].Trim() }
        }
    }
    # the ffmpeg probe is the real test and works identically on every OS
    if ($tools['ffmpeg'].Path) {
        if ((Test-NvencEncoder $tools['ffmpeg'].Path 'hevc_nvenc') -or (Test-NvencEncoder $tools['ffmpeg'].Path 'h264_nvenc')) {
            $hasNvenc = $true
        }
    }
} catch { }
if ($hasNvenc)  { Write-Ok "NVENC ready on: $gpuName -> GPU video encoding, very fast" }
elseif ($osName -eq 'macos') { Write-Warn2 "$($gpuName): no NVENC on macOS -> video will use CPU (x265/SVT-AV1)" }
elseif ($gpuName -ne '(no NVIDIA GPU)') { Write-Warn2 "Found $gpuName but NVENC is not usable -> will use CPU" }
else { Write-Warn2 "No NVIDIA GPU -> video will use CPU (x265), slower but still good" }

# ============================================================ AV1 NVENC (40xx series)
$hasAv1Nvenc = $false
if ($hasNvenc -and $tools['ffmpeg'].Path) {
    try {
        if (Test-NvencEncoder $tools['ffmpeg'].Path 'av1_nvenc') {
            $hasAv1Nvenc = $true; Write-Ok "AV1 NVENC available (RTX 40xx series)"
        }
    } catch { }
}

# ============================================================ user preferences
# First setup asks; later runs reuse the stored answers unless -Force.
# Everything is written explicitly into config.json so the choice is visible.
Write-Step "Preferences"
$priorCodec = if ($prior.ContainsKey('codec')) { [string]$prior['codec'] } else { $null }
$priorConvExt = if ($prior.ContainsKey('convert_extension')) { [bool]$prior['convert_extension'] } else { $null }
$interactive = ($Host.Name -eq 'ConsoleHost')

# video codec preference (default H.265/HEVC)
$preferAv1 = ($priorCodec -eq 'av1')
if ($priorCodec -and -not $Force) {
    Write-Ok "Video codec preference kept from earlier setup: $(if ($preferAv1) { 'AV1' } else { 'H.265/HEVC' })"
} elseif (-not $interactive) {
    Write-Info "Non-interactive session -> codec defaults to H.265/HEVC"
    $preferAv1 = $false
} elseif ($hasAv1Nvenc) {
    $ans = Read-Host "Prefer AV1 over H.265? ~15-25% smaller files, playback needs newer devices [y/N]"
    $preferAv1 = ($ans -match '^(y|yes)$')
    Write-Host "  -> codec preference: $(if ($preferAv1) { 'AV1' } else { 'H.265/HEVC' })"
} else {
    Write-Warn2 "AV1 hardware encoding not available on this GPU -> keeping H.265/HEVC default"
    $preferAv1 = $false
}

# extension conversion preference (default: keep the original extension)
$convertExt = [bool]$priorConvExt
if ($null -ne $priorConvExt -and -not $Force) {
    Write-Ok "File name preference kept from earlier setup: $(if ($convertExt) { 'auto-rename (.mov->.mp4, .heic->.jpg)' } else { 'keep original extensions' })"
} elseif (-not $interactive) {
    Write-Info "Non-interactive session -> original file extensions are kept"
    $convertExt = $false
} else {
    $ans2 = Read-Host "Auto-rename converted files (.mov->.mp4, .heic->.jpg)? N keeps original names [y/N]"
    $convertExt = ($ans2 -match '^(y|yes)$')
    Write-Host "  -> file names: $(if ($convertExt) { 'auto-rename on success' } else { 'keep original extensions' })"
}

# ============================================================ save config
$config = @{
    tools = @{}
    gpu   = @{
        nvenc     = $hasNvenc
        av1_nvenc = $hasAv1Nvenc
        name      = $gpuName
    }
    # explicit preferences so the choice is visible in the file
    codec              = $(if ($preferAv1) { 'av1' } else { 'hevc' })
    convert_extension  = $convertExt
    updated = (Get-Date).ToString('s')
}
foreach ($k in $tools.Keys) {
    $config.tools[$k] = $tools[$k].Path
    if ($tools[$k].ContainsKey('Kind')) { $config.tools["$k`_kind"] = $tools[$k].Kind }
}
$config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
Write-Ok "Config saved: $script:ConfigPath"

# ============================================================ verify + summary
Write-Step "Verification"
$rows = @()
foreach ($k in @('ffmpeg','ffprobe','cjpeg','oxipng','pngquant')) {
    $t = $tools[$k]
    $ver = ''
    if ($t.Path) {
        try {
            $out = & $t.Path -version 2>&1 | Select-Object -First 1
            if (-not $out) { $out = & $t.Path --version 2>&1 | Select-Object -First 1 }
            $ver = ($out | Out-String).Trim()
            if ($ver.Length -gt 70) { $ver = $ver.Substring(0, 70) }
        } catch { $ver = '(could not read version)' }
    }
    $rows += [pscustomobject]@{
        Tool    = $k
        Status  = $(if ($t.Path) { 'OK' } else { 'MISSING' })
        Source  = $t.Source
        Version = $ver
    }
}
$rows | Format-Table -AutoSize

$missing = $rows | Where-Object Status -eq 'MISSING'
if ($tools['ffmpeg'].Path -and $tools['ffprobe'].Path) {
    Write-Host "`nSetup COMPLETE. You can use Optimize-Media.ps1 now." -ForegroundColor Green
    if ($missing) {
        Write-Host "Some optional tools are missing but core functionality still works:" -ForegroundColor Yellow
        $missing | ForEach-Object { Write-Host "   - $($_.Tool)" -ForegroundColor Yellow }
    }
    Write-Host "`nQuick start:" -ForegroundColor Cyan
    Write-Host "   .\Optimize-Media.ps1 `"\\NAS\share\path\to\media`""
    $wrapHint = if ($osName -eq 'windows') { "   (or drag-and-drop a folder onto Optimize-Media.cmd)" } else { "   (or run: ./Optimize-Media.sh <path>)" }
    Write-Host $wrapHint
} else {
    Write-Host "`nSetup FAILED: ffmpeg/ffprobe are required. Check your network and re-run setup.ps1" -ForegroundColor Red
    exit 1
}

# clean temp downloads
Remove-Item $dlDir -Recurse -Force -ErrorAction SilentlyContinue

# ============================================================ benchmark -> performance defaults
$bench = Join-Path $script:RootDir 'Benchmark-Machine.ps1'
if (Test-Path $bench) {
    & $bench
}
