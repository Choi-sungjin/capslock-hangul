<#
.SYNOPSIS
  Builds and installs CapsLockHangul for the current user into Documents\CapsLockHangul (no elevation).
.PARAMETER AllowRunKeyFallback
  Only if scheduled task registration fails: register HKCU\...\Run\CapsLockHangul instead.
.PARAMETER SkipSelfTest
  Skip "CapsLockHangul.exe --self-test" on the freshly built binary.
.PARAMETER DedicatedHangulHold
  Keep a dedicated Hangul key held as Right Alt. Only for verified make/break hardware.
.PARAMETER DedicatedHangulPulse
  Use the safe default dedicated-key pulse mode. Right Alt position still supports hold.
#>
[CmdletBinding()]
param(
    [switch]$AllowRunKeyFallback,
    [switch]$DedicatedHangulHold,
    [switch]$DedicatedHangulPulse,
    [switch]$SkipSelfTest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'common.ps1')
if ($DedicatedHangulHold -and $DedicatedHangulPulse) { throw 'Choose only one dedicated-key mode.' }

$ctx = Get-CapsContext
if ($ctx.IsInstalledCopy) { throw 'Run install.ps1 from the repository checkout, not from the installed folder.' }
Assert-CapsInstallDir $ctx
foreach ($name in $CapsRuntimeScripts) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw "Missing runtime script: $name" }
}

# ---- 1. Build and self-test before touching anything installed.
& (Join-Path $PSScriptRoot 'build.ps1')
$newExe = Join-Path $PSScriptRoot ('bin\' + $CapsExeName)

if (-not $SkipSelfTest) {
    $report = Join-Path $env:TEMP ('CapsLockHangul-selftest-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $rc = Invoke-CapsExe $newExe @('--self-test', '--report', $report) 120
    if ($rc -ne 0) { throw "Self-test failed (exit code $rc). Report: $report" }
    Write-Host "Self-test passed. Report: $report"
}

# ---- 2. Preflight ownership checks (no changes yet).
$dirExisted = Test-Path -LiteralPath $ctx.InstallDir -PathType Container
$marker = Read-CapsMarker $ctx
if ($marker.State -eq 'Invalid') { throw "Refusing: $($ctx.MarkerPath) does not belong to this install ($($marker.Reason))." }
$launchArguments = Get-CapsConfiguredArguments $ctx
if ($PSBoundParameters.ContainsKey('DedicatedHangulHold')) {
    $launchArguments = if ($DedicatedHangulHold) { '--dedicated-hold' } else { '' }
}
if ($DedicatedHangulPulse) { $launchArguments = '' }
if ($dirExisted -and $marker.State -eq 'Missing' -and @(Get-ChildItem -LiteralPath $ctx.InstallDir -Force).Count -gt 0) {
    throw "Refusing: $($ctx.InstallDir) exists, is not empty and has no install marker."
}
$taskBefore = Get-CapsTaskInfo $ctx
if ($taskBefore.Exists -and -not $taskBefore.Owned) {
    throw "Refusing: scheduled task '$($ctx.TaskName)' exists but is not ours ($($taskBefore.Reason))."
}
$runBefore = Get-CapsRunValueInfo $ctx

# ---- 3. Back up current files, then stop the old instance gracefully.
$managedFiles = @($CapsExeName) + $CapsRuntimeScripts + @($CapsMarkerName)
foreach ($name in $managedFiles) {
    $path = Join-Path $ctx.InstallDir $name
    if (Test-CapsReparsePoint $path) { throw "Refusing: $path is a reparse point (symlink/junction)." }
    if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Refusing: $path is not a file." }
}
$backupDir = Join-Path $env:TEMP ('CapsLockHangul-backup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backupDir | Out-Null
$backedUp = @{}
foreach ($name in $managedFiles) {
    $path = Join-Path $ctx.InstallDir $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir $name)
        $backedUp[$name] = $true
    }
}

function Remove-Backup {
    foreach ($name in @($backedUp.Keys)) { Remove-CapsOwnedFile $backupDir $name }
    [void](Remove-CapsDirIfEmpty $backupDir)
}

$controlExe = if ($backedUp.ContainsKey($CapsExeName)) { $ctx.ExePath } else { $newExe }
try {
    $wasRunning = Test-CapsRunning $controlExe
    if ($wasRunning) {
        Write-Host 'Stopping running instance...'
        Stop-CapsInstance $controlExe
    }
} catch {
    Remove-Backup
    throw
}

# ---- 4. Install, register startup, start, verify. Roll back on any failure.
$taskWritten = $false
$runWritten  = $false
try {
    if (-not $dirExisted) { New-Item -ItemType Directory -Path $ctx.InstallDir | Out-Null }
    Copy-Item -LiteralPath $newExe -Destination $ctx.ExePath -Force
    foreach ($name in $CapsRuntimeScripts) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $ctx.InstallDir $name) -Force
    }

    try {
        Register-CapsTaskXml $ctx (New-CapsTaskXml $ctx $launchArguments)
        $taskWritten = $true
        $mode = 'Task'
        Write-Host "Registered scheduled task '$($ctx.TaskName)'."
    } catch {
        $taskError = $_.Exception.Message
        if (-not $AllowRunKeyFallback) {
            throw "Scheduled task registration failed: $taskError  (Re-run with -AllowRunKeyFallback to use HKCU Run instead.)"
        }
        Write-Warning "Scheduled task registration failed: $taskError"
        Write-Warning "Falling back to HKCU Run value '$($ctx.RunValueName)'. No scheduled task is configured."
        Set-CapsRunValue $ctx $launchArguments
        $runWritten = $true
        $mode = 'RunKey'
    }

    Write-CapsMarker $ctx $mode $launchArguments

    if ($mode -eq 'Task') { Start-CapsTask $ctx }
    else { Start-CapsProcess $ctx.ExePath $launchArguments }
    if (-not (Wait-CapsRunning $ctx.ExePath $true 15)) { throw 'Installed app did not report running (--status) within 15 seconds.' }
} catch {
    $installError = $_
    Write-Warning "Install failed: $($installError.Exception.Message)"
    if ($taskWritten) {
        try {
            $failedTask = Get-CapsTask $ctx
            Write-Warning ("Task diagnostic: state={0}, lastResult=0x{1}, lastRun={2}" -f $failedTask.State, ([int32]$failedTask.LastTaskResult).ToString('X8'), $failedTask.LastRunTime)
            Write-Warning ("Task action: {0}; working directory: {1}; executable exists: {2}" -f $failedTask.Definition.Actions.Item(1).Path, $failedTask.Definition.Actions.Item(1).WorkingDirectory, (Test-Path -LiteralPath $ctx.ExePath))
        } catch { Write-Warning "Task diagnostics unavailable: $($_.Exception.Message)" }
    }
    Write-Warning 'Rolling back...'
    $rollbackOk = $true

    try {
        if ((Test-Path -LiteralPath $ctx.ExePath -PathType Leaf) -and (Test-CapsRunning $ctx.ExePath)) { Stop-CapsInstance $ctx.ExePath }
    } catch { $rollbackOk = $false; Write-Warning "Could not stop new instance: $($_.Exception.Message)" }

    if ($taskWritten) {
        try {
            if ($taskBefore.Exists) { Register-CapsTaskXml $ctx $taskBefore.Xml } else { Remove-CapsOwnedTask $ctx }
        } catch { $rollbackOk = $false; Write-Warning "Could not restore scheduled task: $($_.Exception.Message)" }
    }
    if ($runWritten) {
        try { Restore-CapsRunValue $ctx $runBefore }
        catch { $rollbackOk = $false; Write-Warning "Could not restore HKCU Run value: $($_.Exception.Message)" }
    }

    foreach ($name in $managedFiles) {
        $dest = Join-Path $ctx.InstallDir $name
        try {
            if ($backedUp.ContainsKey($name)) { Copy-Item -LiteralPath (Join-Path $backupDir $name) -Destination $dest -Force }
            else { Remove-CapsOwnedFile $ctx.InstallDir $name }
        } catch { $rollbackOk = $false; Write-Warning "Could not restore ${name}: $($_.Exception.Message)" }
    }
    # First install (dir was absent or empty, so all residue is ours, e.g. app logs): remove the dir if
    # empty, otherwise keep an ownership marker so a later install/uninstall can proceed.
    if ($marker.State -eq 'Missing' -and (Test-Path -LiteralPath $ctx.InstallDir -PathType Container)) {
        try {
            if (@(Get-ChildItem -LiteralPath $ctx.InstallDir -Force).Count -eq 0) {
                if (-not $dirExisted) { [void](Remove-CapsDirIfEmpty $ctx.InstallDir) }
            } else {
                Write-CapsMarker $ctx 'Uninstalled'
                Write-Warning "Residual files kept in $($ctx.InstallDir) with an ownership marker."
            }
        } catch { $rollbackOk = $false; Write-Warning "Could not finalize install folder: $($_.Exception.Message)" }
    }

    if ($rollbackOk -and $wasRunning -and $backedUp.ContainsKey($CapsExeName)) {
        try {
            Start-CapsProcess $ctx.ExePath (Get-CapsConfiguredArguments $ctx)
            Write-Host 'Previous version restored and restarted.'
        } catch { Write-Warning "Could not restart previous version: $($_.Exception.Message)" }
    }

    if ($rollbackOk) { Remove-Backup } else { Write-Warning "Rollback incomplete. Previous files kept in: $backupDir" }
    throw $installError
}

# ---- 5. Success: drop the stale registration of the other startup mode (owned only), clean backup.
try {
    if ($mode -eq 'Task' -and $runBefore.Owned) { Remove-CapsOwnedRunValue $ctx; Write-Host 'Removed old HKCU Run value.' }
    if ($mode -eq 'RunKey' -and $taskBefore.Owned) { Remove-CapsOwnedTask $ctx; Write-Host 'Removed old scheduled task.' }
} catch { Write-Warning "Could not remove stale startup entry: $($_.Exception.Message)" }
Remove-Backup

Write-Host ''
Write-Host "Installed : $($ctx.ExePath)"
Write-Host "Startup   : $(if ($mode -eq 'Task') { "scheduled task '$($ctx.TaskName)'" } else { "HKCU Run value '$($ctx.RunValueName)'" })"
Write-Host 'Status    : running'
Write-Host "Manage    : $($ctx.InstallDir)\status.ps1 | stop.ps1 | start.ps1 | uninstall.ps1"
