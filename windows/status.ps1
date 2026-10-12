<#
.SYNOPSIS
  Reports install, startup registration and run state. Exit code: 0 ready, 3 absent, 4 starting/stopping, 1 error/unknown.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'common.ps1')

$ctx = Get-CapsContext
$marker = Read-CapsMarker $ctx
Write-Host "Install dir : $($ctx.InstallDir)"
Write-Host "Marker      : $($marker.State)$(if ($marker.Reason) { " ($($marker.Reason))" })"
if ($marker.State -eq 'Valid') { Write-Host "Startup mode: $($marker.Data.startupMode)" }
Write-Host "Arguments   : $(Get-CapsConfiguredArguments $ctx)"

try {
    $task = Get-CapsTaskInfo $ctx
    $taskText = if (-not $task.Exists) { 'absent' }
                elseif ($task.Owned) { 'present, owned (state {0}: 1=disabled 3=ready 4=running)' -f $task.State }
                else { "present, NOT ours ($($task.Reason))" }
} catch { $taskText = "query failed: $($_.Exception.Message)" }
Write-Host "Task        : $($ctx.TaskName) - $taskText"

$run = Get-CapsRunValueInfo $ctx
$runText = if (-not $run.Exists) { 'absent' } elseif ($run.Owned) { 'present, owned' } else { "present, NOT ours ($($run.Data))" }
Write-Host "HKCU Run    : $($ctx.RunValueName) - $runText"

$exe = Resolve-CapsExe $ctx
if (-not $exe) { Write-Host 'Executable  : not found'; exit 1 }
Write-Host "Executable  : $($exe.Path) ($($exe.Source))"

$rc = Invoke-CapsExe $exe.Path @('--status')
switch ($rc) {
    0       { Write-Host 'State       : running' }
    3       { Write-Host 'State       : not running' }
    4       { Write-Host 'State       : starting or stopping (not ready yet)' }
    default { Write-Host "State       : unknown (--status exit code $rc)"; $rc = 1 }
}
exit $rc
