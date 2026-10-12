<#
.SYNOPSIS
  Gracefully stops CapsLockHangul, removes its owned startup registration and owned files.
  Logs (Documents\CapsLockHangul\logs) are kept unless -RemoveLogs is given.
#>
[CmdletBinding()]
param(
    [switch]$RemoveLogs
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'common.ps1')

$ctx = Get-CapsContext
Assert-CapsInstallDir $ctx

$marker = Read-CapsMarker $ctx
if ($marker.State -eq 'Invalid') { throw "Refusing: $($ctx.MarkerPath) does not belong to this install ($($marker.Reason))." }
if ($marker.State -eq 'Missing' -and (Test-Path -LiteralPath $ctx.InstallDir -PathType Container) -and
    @(Get-ChildItem -LiteralPath $ctx.InstallDir -Force).Count -gt 0) {
    throw "Refusing: $($ctx.InstallDir) has no install marker; inspect it manually."
}

# ---- 1. Graceful stop; abort before changing anything if it fails.
$exe = Resolve-CapsExe $ctx
if ($exe) {
    if (Test-CapsRunning $exe.Path) {
        Write-Host 'Stopping running instance...'
        Stop-CapsInstance $exe.Path
    }
} else {
    Write-Warning 'No CapsLockHangul.exe available to query; skipping stop.'
}

# ---- 2. Startup registration (owned only).
$task = Get-CapsTaskInfo $ctx
if ($task.Owned) { Remove-CapsOwnedTask $ctx; Write-Host "Removed scheduled task '$($ctx.TaskName)'." }
elseif ($task.Exists) { Write-Warning "Scheduled task '$($ctx.TaskName)' left untouched: $($task.Reason)" }

$run = Get-CapsRunValueInfo $ctx
if ($run.Owned) { Remove-CapsOwnedRunValue $ctx; Write-Host "Removed HKCU Run value '$($ctx.RunValueName)'." }
elseif ($run.Exists) { Write-Warning "HKCU Run value '$($ctx.RunValueName)' left untouched: $($run.Data)" }

# ---- 3. Owned files (marker removed last so a failed run can be repeated).
if ($marker.State -ne 'Valid') { Write-Host 'No installed files to remove.'; exit 0 }

foreach ($name in @($CapsExeName) + $CapsRuntimeScripts) { Remove-CapsOwnedFile $ctx.InstallDir $name }

if ($RemoveLogs -and (Test-Path -LiteralPath $ctx.LogDir -PathType Container)) {
    if (Test-CapsReparsePoint $ctx.LogDir) { throw "Log folder is a reparse point; refusing: $($ctx.LogDir)" }
    Get-ChildItem -LiteralPath $ctx.LogDir -Filter '*.log' -File -Force | Where-Object { $_.Extension -ieq '.log' } | ForEach-Object { Remove-CapsOwnedFile $ctx.LogDir $_.Name }
    if (-not (Remove-CapsDirIfEmpty $ctx.LogDir)) { Write-Warning "Kept non-log files in $($ctx.LogDir)" }
}

# Remove the marker only if the folder can then be fully removed; otherwise keep ownership for reinstall.
$remaining = @(Get-ChildItem -LiteralPath $ctx.InstallDir -Force | Where-Object { $_.Name -ne $CapsMarkerName })
if ($remaining.Count -eq 0) {
    Remove-CapsOwnedFile $ctx.InstallDir $CapsMarkerName
    [void](Remove-CapsDirIfEmpty $ctx.InstallDir)
    Write-Host "Removed $($ctx.InstallDir)."
} else {
    Write-CapsMarker $ctx 'Uninstalled'
    Write-Host "Kept $($ctx.InstallDir) with ownership marker (remaining: $(($remaining | ForEach-Object Name) -join ', '))."
}
Write-Host 'Uninstalled.'
