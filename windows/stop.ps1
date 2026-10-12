<#
.SYNOPSIS
  Gracefully stops this user's CapsLockHangul instance via "CapsLockHangul.exe --stop". Never kills processes.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'common.ps1')

$ctx = Get-CapsContext
$exe = Resolve-CapsExe $ctx
if (-not $exe) { throw "CapsLockHangul.exe not found: not installed at $($ctx.InstallDir) and not built in the repository." }

if (-not (Test-CapsRunning $exe.Path)) { Write-Host 'Not running.'; exit 0 }
Stop-CapsInstance $exe.Path
Write-Host 'Stopped.'
