<#
.SYNOPSIS
  Starts CapsLockHangul for the current user (installed copy preferred, else repository bin\ build).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'common.ps1')

$ctx = Get-CapsContext
$exe = Resolve-CapsExe $ctx
if (-not $exe) { throw "CapsLockHangul.exe not found: not installed at $($ctx.InstallDir) and not built in the repository." }

if (Test-CapsRunning $exe.Path) { Write-Host 'Already running.'; exit 0 }

$started = $false
if ($exe.Source -eq 'Installed' -and (Read-CapsMarker $ctx).Data.startupMode -eq 'Task') {
    try {
        $task = Get-CapsTaskInfo $ctx
        if ($task.Owned) { Start-CapsTask $ctx; $started = $true }
        else { Write-Warning "Scheduled task '$($ctx.TaskName)' missing or not ours ($($task.Reason)); starting directly." }
    } catch { Write-Warning "Could not start via scheduled task: $($_.Exception.Message); starting directly." }
}
if (-not $started) {
    Start-CapsProcess $exe.Path (Get-CapsConfiguredArguments $ctx)
}

if (-not (Wait-CapsRunning $exe.Path $true 15)) { throw 'CapsLockHangul did not report running (--status) within 15 seconds.' }
Write-Host "Running ($($exe.Source): $($exe.Path))."
