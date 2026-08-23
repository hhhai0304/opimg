# Optimize-Media

Compress images and videos on Windows with the best possible quality-to-size ratio. Supports local paths and network shares (SMB/UNC), GPU acceleration via NVIDIA NVENC, and detailed before/after reporting.

## Features

- **Parallel by default** — separate worker pools for images (CPU) and videos (GPU), tuned automatically to your machine
- **Auto-benchmark** — `setup.ps1` measures CPU cores, RAM, and how many NVENC sessions your GPU can run at once, then writes sensible defaults to `config.json`
- **Live progress UI** — a single in-place status block (progress bar, active workers, ETA, recent completions) instead of scrolling spam; falls back to periodic lines when output is redirected
- **Recursive scan** — point it at a folder and it processes every image/video in all subfolders
- **GPU-accelerated video** — HEVC/AV1 encoding via NVIDIA NVENC (auto-detected), falls back to CPU (x265/x264) when unavailable
- **Smart image compression** — lossless first (jpegoptim, oxipng), light lossy only when it saves meaningfully (pngquant)
- **Safe by design** — compresses to a local temp file, verifies the output (full decode + duration check), only replaces the original when it's smaller and valid
- **Keeps formats** — `.mp4` stays `.mp4`, `.jpg` stays `.jpg`; nothing breaks
- **SMB aware** — works directly on UNC paths, copies results back only after local verification
- **Resumable** — a processing history means re-runs skip already-compressed files
- **Reports** — console summary + detailed CSV per run (before/after, savings %, tool used, duration)

## Quick start

```powershell
# 1. One-time setup: downloads all required tools (ffmpeg, oxipng, pngquant, jpegoptim)
.\setup.ps1

# 2. Compress a folder or a single file (local path or UNC/SMB)
.\Optimize-Media.ps1 -Path "\\NAS\share\Photos"
```

Or simply **drag-and-drop a folder onto `Optimize-Media.cmd`**.

## Presets

| Preset | Video codec | Use case |
|---|---|---|
| `fast` | HEVC, higher CQ | Quick pass, good savings |
| `balanced` *(default)* | HEVC cq25 | Best quality/speed trade-off |
| `max` | AV1 (RTX 40xx) or HEVC | Maximum compression, slower |
| `archive` | H.264 | Compatibility with very old devices |

```powershell
.\Optimize-Media.ps1 <path> -Preset max
```

## Options

| Flag | Description |
|---|---|
| `-Backup` | Keep originals in `.\backup\` before replacing |
| `-WhatIf` | Scan and estimate only — no changes |
| `-Force` | Recompress files already in history |
| `-Codec hevc\|h264\|av1` | Force a specific video codec |
| `-MinSaving 5` | Skip replacement if savings are below X % |
| `-Include` / `-Exclude` | Filter by extension (e.g. `-Include jpg,png`) |
| `-ImageWorkers N` | Override parallel image workers for this run |
| `-VideoWorkers N` | Override parallel video workers for this run |

## Performance tuning

`setup.ps1` runs `Benchmark-Machine.ps1`, which measures your CPU cores, RAM, and the number of concurrent NVENC sessions your GPU actually supports. Results are written to `config.json`:

```json
"performance": {
    "imageWorkers": 12,
    "videoWorkers": 3,
    "nvencSessions": 4
}
```

Edit these values to tune throughput manually, or re-run `.\Benchmark-Machine.ps1` (use `-Force` to discard your manual tuning and re-measure). Per-run overrides: `-ImageWorkers` / `-VideoWorkers`.

## Example output

```
==================================================
  Optimize-Media  |  preset: balanced  |  video: hevc (hevc_nvenc [GPU])
  Workers: 12 images + 3 videos (parallel)
==================================================
Scanned: 752 files (680 images, 72 videos) - 2.14 GB

[################--------]  67.0%  |  504/752 files  |  saved 1.1 GB  |  ETA 3m 12s
  working: wedding_aisle.mp4
  working: party_dance.mp4
  recent: IMG_2041.jpg -74%  |  clip.mp4 -89%

==================================================
  RESULTS
==================================================
  Compressed : 711 files
  Skipped    : 41 files
  Before     : 2.14 GB
  After      : 486.20 MB
  Saved      : 1.67 GB  (77.7%)
  Time       : 12m 04s  (3 MB/s processed)
    Images:  680 files | 512 MB -> 198 MB | saved 314 MB (61%)
    Videos:   31 files | 1.63 GB -> 288 MB | saved 1.36 GB (84%)
```

## How it works

1. `setup.ps1` downloads portable binaries into `tools\` (no admin needed), detects your GPU's NVENC capabilities, and benchmarks your machine — all saved to `config.json`.
2. `Optimize-Media.ps1` scans the target, splits work into two queues, and processes them **in parallel**:
   - **Image pool** (default: logical cores − 4 workers) — jpegoptim (lossless) / mozjpeg for JPEG, oxipng → pngquant for PNG, ffmpeg for GIF/WebP/others
   - **Video pool** (default: NVENC session count − 1 workers) — ffmpeg with NVENC (GPU) or x265/x264 (CPU), audio copied untouched
3. Each worker compresses to a local temp file, verifies the output (decodes cleanly, video duration matches), and only then replaces the original. Files that would save less than `-MinSaving`% keep the original.
4. A single in-place progress block shows overall %, active workers, ETA, and recent completions. Every processed file is logged to `logs\history.csv` so re-runs skip them.

## File layout

```
Optimize-Media.ps1      Main CLI (parallel engine)
Optimize-Media.cmd      Drag-and-drop wrapper
setup.ps1               One-time tool installer
Benchmark-Machine.ps1   Measures your machine, writes performance defaults
tools\                  Portable binaries (gitignored, created by setup)
logs\                   CSV reports + history (gitignored)
backup\                 Originals when using -Backup (gitignored)
config.json             Machine-specific config (gitignored, created by setup)
```

## Moving to another PC

Copy the whole folder, run `.\setup.ps1` — done. If you also copy `tools\`, no internet is needed.

## Requirements

- Windows 10/11 with PowerShell 5.1+
- Optional: NVIDIA GPU for NVENC (GTX 10xx+ for HEVC, RTX 40xx for AV1)
- Internet access for the first `setup.ps1` run (tool downloads)
