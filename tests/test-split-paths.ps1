# Unit tests for Expand-PathArg / Split-PathLine (dot-source the main script's functions only).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Extract just the two functions from Optimize-Media.ps1 to avoid running the whole script.
$src = Get-Content (Join-Path $PSScriptRoot '..\Optimize-Media.ps1') -Raw
$start = $src.IndexOf('# Argument channel')
$end = $src.IndexOf('# ============================================================ load config')
if ($start -lt 0 -or $end -lt 0 -or $end -le $start) { throw 'Could not locate function block' }
Invoke-Expression $src.Substring($start, $end - $start)

$base = Join-Path $env:TEMP 'opimg-test'
Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
'part 1', 'part2', 'my photos', 'a b c' | ForEach-Object {
    New-Item -ItemType Directory -Path (Join-Path $base $_) -Force | Out-Null
}

$fail = 0
function Assert-Eq($got, $want, $label) {
    $g = ($got -join '|'); $w = ($want -join '|')
    if ($g -eq $w) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL  $label`n      got : $g`n      want: $w" -ForegroundColor Red }
}

Assert-Eq (Split-PathLine "`"$base\part 1`" `"$base\part2`"") @("$base\part 1","$base\part2") 'C1 both quoted'
Assert-Eq (Split-PathLine "`"$base\part 1`" $base\part2")     @("$base\part 1","$base\part2") 'C2 MIXED quoted + bare (old bug)'
Assert-Eq (Split-PathLine "$base\part2 `"$base\part 1`"")     @("$base\part2","$base\part 1") 'C3 MIXED, bare first'
Assert-Eq (Split-PathLine "$base\part2")                      @("$base\part2")                'C4 single bare path'
Assert-Eq (Split-PathLine "$base\my photos")                  @("$base\my photos")            'C5 single bare path WITH space'
Assert-Eq (Split-PathLine "")                                 @()                             'C6 empty'

Assert-Eq (Expand-PathArg "$base\part 1")                     @("$base\part 1")               'A1 element with space'
Assert-Eq (Expand-PathArg "$base\part 1|$base\part2")         @("$base\part 1","$base\part2") 'B1 .cmd pipe join'
Assert-Eq (Expand-PathArg "")                                 @()                             'A2 empty'

if ($fail -gt 0) { exit 1 } else { Write-Host "`nAll tests passed." -ForegroundColor Green }
