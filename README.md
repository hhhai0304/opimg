# Optimize-Media

Compress images and videos on Windows with the best possible quality-to-size ratio. Supports local paths and network shares (SMB/UNC), GPU acceleration via NVIDIA NVENC, and detailed before/after reporting.

## Features

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

## Example output

```
[3/128] IMG_2041.jpg   4.2 MB -> 1.1 MB  (-74%)  jpegoptim-lossless  0.6s
[4/128] clip.mp4     165.0 MB -> 17.8 MB (-89%)  hevc_nvenc cq25 [GPU]  21s
    Overall: 35% | saved 150 MB | ETA ~4m

==================================================
  RESULTS
==================================================
  Compressed : 87 files
  Skipped    : 41 files
  Before     : 2.14 GB
  After      : 486.20 MB
  Saved      : 1.67 GB  (77.7%)
  Time       : 12m 04s
    Images:   72 files | 512 MB -> 198 MB | saved 314 MB (61%)
    Videos:   15 files | 1.63 GB -> 288 MB | saved 1.36 GB (84%)

Detailed report: logs\report-20260823-161510.csv
```

## How it works

1. `setup.ps1` downloads portable binaries into `tools\` (no admin needed) and detects your GPU's NVENC capabilities, saving everything to `config.json`.
2. `Optimize-Media.ps1` scans the target, classifies files, and routes each to the right pipeline:
   - **JPEG** → jpegoptim (lossless) / mozjpeg
   - **PNG** → oxipng (lossless) → pngquant (light lossy if still large)
   - **GIF/WebP/others** → ffmpeg re-encode
   - **Video** → ffmpeg with NVENC (GPU) or x265/x264 (CPU), audio copied untouched
3. Each output is verified (decodes cleanly, video duration matches) before the original is replaced. Files that would save less than `-MinSaving`% keep the original.
4. Every processed file is logged to `logs\history.csv` so re-runs skip them.

## File layout

```
Optimize-Media.ps1   Main CLI
Optimize-Media.cmd   Drag-and-drop wrapper
setup.ps1            One-time tool installer
tools\               Portable binaries (gitignored, created by setup)
logs\                CSV reports + history (gitignored)
backup\              Originals when using -Backup (gitignored)
config.json          Machine-specific config (gitignored, created by setup)
```

## Moving to another PC

Copy the whole folder, run `.\setup.ps1` — done. If you also copy `tools\`, no internet is needed.

## Requirements

- Windows 10/11 with PowerShell 5.1+
- Optional: NVIDIA GPU for NVENC (GTX 10xx+ for HEVC, RTX 40xx for AV1)
- Internet access for the first `setup.ps1` run (tool downloads)
