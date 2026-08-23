@echo off
rem Optimize-Media - drag-and-drop one or more folders/files onto this to compress them
rem Or run: Optimize-Media.cmd "path1" "path2" [preset]

setlocal
set "SCRIPT_DIR=%~dp0"
set "PRESET=balanced"
set "ARGS="
set "USEPRESET=0"

rem A second argument that names a known preset is used as the preset.
if /i "%~2"=="fast"     set "USEPRESET=1"
if /i "%~2"=="balanced" set "USEPRESET=1"
if /i "%~2"=="max"      set "USEPRESET=1"
if /i "%~2"=="archive"  set "USEPRESET=1"
if "%USEPRESET%"=="1" set "PRESET=%~2"

if "%USEPRESET%"=="1" (
    set "ARGS=%~1"
    shift
    shift
)

:collect
if "%~1"=="" goto :run
if "%ARGS%"=="" ( set "ARGS=%~1" ) else ( set "ARGS=%ARGS%|%~1" )
shift
goto :collect
:run

if "%ARGS%"=="" goto :usage
goto :go
:usage
echo.
echo   Usage:
echo     1. Drag-and-drop one or more folders/files onto this .cmd
echo     2. Or run: Optimize-Media.cmd "D:\Photos" balanced
echo.
echo   Presets: fast ^| balanced (default) ^| max ^| archive
echo.
set /p TARGET="Enter path (folder or file): "
set "ARGS=%TARGET%"
:go

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Optimize-Media.ps1" -Path "%ARGS%" -Preset %PRESET%

echo.
pause
