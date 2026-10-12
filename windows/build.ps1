<#
.SYNOPSIS
  Compiles windows\src\*.cs into windows\bin\CapsLockHangul.exe with the inbox .NET Framework 4.x csc.exe.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$srcDir = Join-Path $PSScriptRoot 'src'
$binDir = Join-Path $PSScriptRoot 'bin'
$outExe = Join-Path $binDir 'CapsLockHangul.exe'

$frameworkDir = if ([Environment]::Is64BitOperatingSystem) { 'Framework64' } else { 'Framework' }
$csc = Join-Path $env:WINDIR "Microsoft.NET\$frameworkDir\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw "C# compiler not found: $csc (.NET Framework 4.x is required)." }

if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) { throw "Source folder not found: $srcDir" }
$sources = @(Get-ChildItem -LiteralPath $srcDir -Filter '*.cs' -File | Sort-Object Name | ForEach-Object { $_.FullName })
if ($sources.Count -eq 0) { throw "No .cs files in $srcDir" }

if (-not (Test-Path -LiteralPath $binDir -PathType Container)) { New-Item -ItemType Directory -Path $binDir | Out-Null }

$cscArgs = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/codepage:65001',
    '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll',
    "/out:$outExe"
) + $sources

Write-Host "Compiling $($sources.Count) file(s) with $csc"
& $csc @cscArgs
$rc = $LASTEXITCODE
if ($rc -ne 0) { throw "csc.exe failed with exit code $rc." }
if (-not (Test-Path -LiteralPath $outExe -PathType Leaf)) { throw "csc.exe reported success but $outExe is missing." }
Write-Host "Built $outExe"
