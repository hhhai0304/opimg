@echo off
rem Optimize-Media - drag-and-drop a folder/file onto this to compress
rem or run: Optimize-Media.cmd "path\to\folder" [preset]

setlocal
set "SCRIPT_DIR=%~dp0"
set "TARGET=%~1"
set "PRESET=%~2"

if "%TARGET%"=="" (
    echo.
    echo   Usage:
    echo     1. Drag-and-drop a folder or file onto this .cmd
    echo     2. Or run: Optimize-Media.cmd "D:\Photos" balanced
    echo.
    echo   Presets: fast ^| balanced (default) ^| max ^| archive
    echo.
    set /p TARGET="Enter path (folder or file): "
)
if "%PRESET%"=="" set "PRESET=balanced"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Optimize-Media.ps1" -Path "%TARGET%" -Preset %PRESET% %3 %4 %5 %6

echo.
pause
