# Shared helpers for the CapsLockHangul deployment scripts.
# Dot-source only. Windows PowerShell 5.1 compatible, no external modules.
Set-StrictMode -Version 2.0

$script:CapsAppName        = 'CapsLockHangul'
$script:CapsExeName        = 'CapsLockHangul.exe'
$script:CapsMarkerName     = 'install.json'
$script:CapsLogDirName     = 'logs'
$script:CapsRuntimeScripts = @('common.ps1', 'start.ps1', 'stop.ps1', 'status.ps1', 'uninstall.ps1')
$script:CapsRunKeyPath     = 'Software\Microsoft\Windows\CurrentVersion\Run'
$script:CapsTaskNamespace  = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
$script:CapsStatusRunning  = 0
$script:CapsStatusAbsent   = 3
$script:CapsStatusNotReady = 4

# ---------------------------------------------------------------- paths

function Get-CapsFullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-CapsSamePath([string]$A, [string]$B) {
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    try { return (Get-CapsFullPath $A) -ieq (Get-CapsFullPath $B) } catch { return $false }
}

function Test-CapsReparsePoint([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Get-CapsContext {
    # MSIX desktop apps virtualize LocalAppData writes. Documents is visible to
    # both the installer and the ordinary interactive Task Scheduler process.
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documents)) { throw 'Documents folder is unavailable.' }
    if (-not [System.IO.Path]::IsPathRooted($documents) -or $documents.StartsWith('\\')) {
        throw "Documents is not a local absolute path: $documents"
    }
    $base = Get-CapsFullPath $documents
    if ($base -ieq ([System.IO.Path]::GetPathRoot($base).TrimEnd('\'))) {
        throw "Documents points at a drive root: $base"
    }

    $identity   = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $installDir = Join-Path $base $script:CapsAppName
    return [pscustomobject]@{
        BaseDir         = $base
        InstallDir      = $installDir
        ExePath         = Join-Path $installDir $script:CapsExeName
        MarkerPath      = Join-Path $installDir $script:CapsMarkerName
        LogDir          = Join-Path $installDir $script:CapsLogDirName
        Sid             = $identity.User.Value
        UserName        = $identity.Name
        TaskName        = '{0}-{1}' -f $script:CapsAppName, $identity.User.Value
        RunValueName    = $script:CapsAppName
        ScriptDir       = $PSScriptRoot
        IsInstalledCopy = (Test-CapsSamePath $PSScriptRoot $installDir)
    }
}

# Refuses to continue unless InstallDir is exactly Documents\CapsLockHangul and not a junction/symlink.
function Assert-CapsInstallDir($Ctx) {
    $dir = Get-CapsFullPath $Ctx.InstallDir
    if ((Split-Path -Leaf $dir) -cne $script:CapsAppName) { throw "Unexpected install folder name: $dir" }
    if (-not (Test-CapsSamePath (Split-Path -Parent $dir) $Ctx.BaseDir)) { throw "Install folder is not directly under Documents: $dir" }
    if (Test-CapsReparsePoint $dir) { throw "Install folder is a reparse point (junction/symlink); refusing: $dir" }
    if ((Test-Path -LiteralPath $dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "Install path exists but is not a folder: $dir"
    }
}

# ---------------------------------------------------------------- install marker

# State: Missing | Valid | Invalid
function Read-CapsMarker($Ctx) {
    if (-not (Test-Path -LiteralPath $Ctx.MarkerPath -PathType Leaf)) {
        return [pscustomobject]@{ State = 'Missing'; Data = $null; Reason = 'no marker file' }
    }
    try {
        $data = Get-Content -LiteralPath $Ctx.MarkerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($data.product -cne $script:CapsAppName) { $reason = "product is '$($data.product)'" }
        elseif ($data.userSid -cne $Ctx.Sid)        { $reason = "installed for SID $($data.userSid)" }
        elseif (-not (Test-CapsSamePath $data.installDir $Ctx.InstallDir)) { $reason = "installDir is '$($data.installDir)'" }
        else { return [pscustomobject]@{ State = 'Valid'; Data = $data; Reason = '' } }
    } catch {
        $reason = "unreadable marker: $($_.Exception.Message)"
        $data = $null
    }
    return [pscustomobject]@{ State = 'Invalid'; Data = $data; Reason = $reason }
}

function Write-CapsMarker($Ctx, [string]$StartupMode, [string]$LaunchArguments = '') {
    $data = [ordered]@{
        product       = $script:CapsAppName
        schemaVersion = 1
        userSid       = $Ctx.Sid
        userName      = $Ctx.UserName
        installDir    = $Ctx.InstallDir
        exePath       = $Ctx.ExePath
        startupMode   = $StartupMode
        launchArguments = $LaunchArguments
        taskName      = $Ctx.TaskName
        runValueName  = $Ctx.RunValueName
        files         = @($script:CapsExeName) + $script:CapsRuntimeScripts
        installedAt   = (Get-Date).ToString('o')
    }
    $json = $data | ConvertTo-Json
    [System.IO.File]::WriteAllText($Ctx.MarkerPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

# Deletes a single owned file by bare name inside InstallDir (or a subfolder name). Never recursive.
function Remove-CapsOwnedFile([string]$Dir, [string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Refusing to delete suspicious file name: $Name" }
    $path = Join-Path $Dir $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if (Test-CapsReparsePoint $path) { throw "Refusing to delete reparse point: $path" }
    Remove-Item -LiteralPath $path
}

function Remove-CapsDirIfEmpty([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $true }
    if (@(Get-ChildItem -LiteralPath $Dir -Force).Count -gt 0) { return $false }
    Remove-Item -LiteralPath $Dir
    return $true
}

# ---------------------------------------------------------------- executable

# All helper invocations of the GUI exe go through here to obtain a reliable exit code.
# Bounded wait: a hung helper (--status/--stop/--self-test) is reported and left alone, never killed.
function Invoke-CapsExe([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec = 30) {
    $quoted = @($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    })
    $p = Start-Process -FilePath $Exe -ArgumentList $quoted -WindowStyle Hidden -PassThru
    [void]$p.Handle  # cache the handle so ExitCode is readable after exit (PS 5.1)
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        throw "Helper '$Exe $($Arguments -join ' ')' did not exit within $TimeoutSec s (PID $($p.Id), not killed)."
    }
    return [int]$p.ExitCode
}

# Returns $true (ready) / $false (absent). A starting instance gets a bounded
# readiness wait; it must never be mistaken for an absent process during update.
function Test-CapsRunning([string]$Exe) {
    $rc = Invoke-CapsExe $Exe @('--status')
    if ($rc -eq $script:CapsStatusRunning) { return $true }
    if ($rc -eq $script:CapsStatusAbsent)  { return $false }
    if ($rc -eq $script:CapsStatusNotReady) {
        if (Wait-CapsRunning $Exe $true 15) { return $true }
        throw "Instance did not become ready within 15 seconds: $Exe"
    }
    throw "Unexpected --status exit code $rc from $Exe"
}

function Wait-CapsRunning([string]$Exe, [bool]$Running, [int]$TimeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $rc = Invoke-CapsExe $Exe @('--status')
        if ($Running -and $rc -eq $script:CapsStatusRunning) { return $true }
        if (-not $Running -and $rc -eq $script:CapsStatusAbsent) { return $true }
        if ($rc -notin @($script:CapsStatusRunning, $script:CapsStatusAbsent, $script:CapsStatusNotReady)) {
            throw "Unexpected --status exit code $rc from $Exe"
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

# Graceful stop only. Never kills processes.
function Stop-CapsInstance([string]$Exe) {
    $rc = Invoke-CapsExe $Exe @('--stop')
    if ($rc -ne 0) { throw "Graceful stop failed (--stop exit code $rc). Nothing was killed; aborting." }
    if (-not (Wait-CapsRunning $Exe $false 15)) {
        throw 'Instance still reports running after --stop. Nothing was killed; aborting.'
    }
}

# Prefers the installed copy (fixed path); falls back to the repository build output.
function Resolve-CapsExe($Ctx) {
    if ((Test-Path -LiteralPath $Ctx.ExePath -PathType Leaf) -and (Read-CapsMarker $Ctx).State -eq 'Valid') {
        return [pscustomobject]@{ Path = $Ctx.ExePath; Source = 'Installed' }
    }
    if (-not $Ctx.IsInstalledCopy) {
        $repoExe = Join-Path $Ctx.ScriptDir ('bin\' + $script:CapsExeName)
        if (Test-Path -LiteralPath $repoExe -PathType Leaf) {
            return [pscustomobject]@{ Path = $repoExe; Source = 'Repository' }
        }
    }
    return $null
}

function Get-CapsConfiguredArguments($Ctx) {
    $marker = Read-CapsMarker $Ctx
    if ($marker.State -eq 'Valid' -and $marker.Data.PSObject.Properties['launchArguments']) {
        $value = [string]$marker.Data.launchArguments
        if ($value -cnotin @('', '--dedicated-hold')) { throw 'Unsupported launch arguments in install marker.' }
        return $value
    }
    return ''
}

function Start-CapsProcess([string]$Exe, [string]$LaunchArguments = '') {
    if ($LaunchArguments -cnotin @('', '--dedicated-hold')) { throw 'Unsupported launch arguments.' }
    $options = @{ FilePath = $Exe; WorkingDirectory = (Split-Path -Parent $Exe); WindowStyle = 'Hidden' }
    if ($LaunchArguments) { $options.ArgumentList = $LaunchArguments }
    Start-Process @options
}

# ---------------------------------------------------------------- scheduled task (Schedule.Service COM, inbox)

function Get-CapsTaskFolder {
    $svc = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    return $svc.GetFolder('\')
}

function Test-CapsNotFoundError($Exception) {
    $e = $Exception
    while ($e) {
        if ($e.HResult -eq -2147024894 -or $e.HResult -eq -2147024893) { return $true }  # 0x80070002 / 0x80070003
        $e = $e.InnerException
    }
    return $false
}

function Get-CapsTask($Ctx) {
    $folder = Get-CapsTaskFolder
    try { return $folder.GetTask($Ctx.TaskName) }
    catch {
        if (Test-CapsNotFoundError $_.Exception) { return $null }
        throw
    }
}

function Resolve-CapsSid([string]$Account) {
    if ([string]::IsNullOrWhiteSpace($Account)) { return $null }
    if ($Account -match '^S-1-') { return $Account }
    try {
        return (New-Object System.Security.Principal.NTAccount $Account).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { return $null }
}

# Returns $null when the task XML is ours (single Exec action on our exe, principal = current user), else a reason.
function Get-CapsTaskForeignReason($Ctx, [string]$XmlText) {
    $doc = [xml]$XmlText
    $ns = New-Object System.Xml.XmlNamespaceManager $doc.NameTable
    $ns.AddNamespace('t', $script:CapsTaskNamespace)
    $actions = @($doc.SelectNodes('/t:Task/t:Actions/*', $ns))
    $execs   = @($doc.SelectNodes('/t:Task/t:Actions/t:Exec', $ns))
    if ($actions.Count -ne 1 -or $execs.Count -ne 1) { return 'task does not have exactly one Exec action' }
    $cmdNode = $execs[0].SelectSingleNode('t:Command', $ns)
    if (-not $cmdNode) { return 'task action has no command' }
    $cmd = [Environment]::ExpandEnvironmentVariables($cmdNode.InnerText.Trim().Trim('"'))
    $argNode = $execs[0].SelectSingleNode('t:Arguments', $ns)
    $arguments = if ($argNode) { $argNode.InnerText.Trim() } else { '' }
    if (-not (Test-CapsSamePath $cmd $Ctx.ExePath)) { return "task action runs '$cmd'" }
    if ($arguments -cnotin @('', '--dedicated-hold')) { return 'task action has unsupported arguments' }
    $principals = @($doc.SelectNodes('/t:Task/t:Principals/t:Principal', $ns))
    if ($principals.Count -ne 1) { return 'task does not have exactly one principal' }
    $actionContext = $doc.SelectSingleNode('/t:Task/t:Actions', $ns).GetAttribute('Context')
    if ($actionContext -and $actionContext -cne $principals[0].GetAttribute('id')) { return 'task action context does not match its principal' }
    $uidNode = $principals[0].SelectSingleNode('t:UserId', $ns)
    if (-not $uidNode -or (Resolve-CapsSid $uidNode.InnerText) -cne $Ctx.Sid) { return 'task principal is not the current user' }
    return $null
}

function Get-CapsTaskInfo($Ctx) {
    $task = Get-CapsTask $Ctx
    if (-not $task) { return [pscustomobject]@{ Exists = $false; Owned = $false; Xml = $null; State = $null; Reason = 'absent' } }
    $xml = $task.Xml
    $reason = Get-CapsTaskForeignReason $Ctx $xml
    return [pscustomobject]@{ Exists = $true; Owned = (-not $reason); Xml = $xml; State = [int]$task.State; Reason = $reason }
}

function New-CapsTaskXml($Ctx, [string]$LaunchArguments = '') {
    if ($LaunchArguments -cnotin @('', '--dedicated-hold')) { throw 'Unsupported launch arguments.' }
    $e = { param($s) [System.Security.SecurityElement]::Escape($s) }
    return @"
<Task version="1.2" xmlns="$($script:CapsTaskNamespace)">
  <RegistrationInfo>
    <Author>$(& $e $Ctx.UserName)</Author>
    <Description>CapsLockHangul per-user startup. Managed by CapsLockHangul install.ps1/uninstall.ps1.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$($Ctx.Sid)</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$($Ctx.Sid)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>4</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $e $Ctx.ExePath)</Command>
      <Arguments>$(& $e $LaunchArguments)</Arguments>
      <WorkingDirectory>$(& $e $Ctx.InstallDir)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

# Creates or updates the task. Callers must have verified the existing task (if any) is owned.
function Register-CapsTaskXml($Ctx, [string]$XmlText) {
    $folder = Get-CapsTaskFolder
    # 6 = TASK_CREATE_OR_UPDATE, 3 = TASK_LOGON_INTERACTIVE_TOKEN; no stored password.
    [void]$folder.RegisterTask($Ctx.TaskName, $XmlText, 6, $null, $null, 3)
}

function Start-CapsTask($Ctx) {
    $task = Get-CapsTask $Ctx
    if (-not $task) { throw "Scheduled task '$($Ctx.TaskName)' not found." }
    [void]$task.Run($null)
}

function Remove-CapsOwnedTask($Ctx) {
    $info = Get-CapsTaskInfo $Ctx
    if (-not $info.Exists) { return }
    if (-not $info.Owned) { throw "Not removing scheduled task '$($Ctx.TaskName)': $($info.Reason)" }
    (Get-CapsTaskFolder).DeleteTask($Ctx.TaskName, 0)
}

# ---------------------------------------------------------------- HKCU Run fallback

function Get-CapsRunValueInfo($Ctx) {
    $expected = '"' + $Ctx.ExePath + '"'
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:CapsRunKeyPath, $false)
    if (-not $key) { return [pscustomobject]@{ Exists = $false; Owned = $false; Data = $null; Kind = $null; Expected = $expected } }
    try {
        $data = $key.GetValue($Ctx.RunValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $data) { return [pscustomobject]@{ Exists = $false; Owned = $false; Data = $null; Kind = $null; Expected = $expected } }
        $kind  = $key.GetValueKind($Ctx.RunValueName)
        $owned = ($data -is [string]) -and (($data.Trim() -ieq $expected) -or ($data.Trim() -ieq $Ctx.ExePath) -or ($data.Trim() -ieq ($expected + ' --dedicated-hold')))
        return [pscustomobject]@{ Exists = $true; Owned = $owned; Data = $data; Kind = $kind; Expected = $expected }
    } finally { $key.Close() }
}

function Set-CapsRunValue($Ctx, [string]$LaunchArguments = '') {
    if ($LaunchArguments -cnotin @('', '--dedicated-hold')) { throw 'Unsupported launch arguments.' }
    $info = Get-CapsRunValueInfo $Ctx
    if ($info.Exists -and -not $info.Owned) { throw "HKCU Run value '$($Ctx.RunValueName)' exists with foreign data; not overwriting." }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:CapsRunKeyPath)
    $command = $info.Expected
    if ($LaunchArguments) { $command += ' ' + $LaunchArguments }
    try { $key.SetValue($Ctx.RunValueName, $command, [Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Close() }
}

# Restores only our named value to a snapshot taken by Get-CapsRunValueInfo.
function Restore-CapsRunValue($Ctx, $Snapshot) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:CapsRunKeyPath)
    try {
        if ($Snapshot.Exists) { $key.SetValue($Ctx.RunValueName, $Snapshot.Data, $Snapshot.Kind) }
        else { $key.DeleteValue($Ctx.RunValueName, $false) }
    } finally { $key.Close() }
}

function Remove-CapsOwnedRunValue($Ctx) {
    $info = Get-CapsRunValueInfo $Ctx
    if (-not $info.Exists) { return }
    if (-not $info.Owned) { throw "Not removing HKCU Run value '$($Ctx.RunValueName)': data is '$($info.Data)'" }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:CapsRunKeyPath, $true)
    try { $key.DeleteValue($Ctx.RunValueName, $false) } finally { $key.Close() }
}
