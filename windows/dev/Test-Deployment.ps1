<#
.SYNOPSIS
  Deployment regressions for Windows PowerShell 5.1 and PowerShell 7.
.DESCRIPTION
  Dot-sources common.ps1 only. Never registers tasks, edits the registry, or
  launches the remapper. Files are confined to a unique child of WorkRoot.
  Run from the checkout with:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows\dev\Test-Deployment.ps1
#>
[CmdletBinding()]
param([string]$WorkRoot = (Join-Path (Get-Location).Path 'work\deployment-tests'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'common.ps1')

$script:DeploymentPasses = 0
$script:DeploymentFailures = New-Object 'System.Collections.Generic.List[string]'
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -cne $Actual) { throw "$Message (expected '$Expected', got '$Actual')" }
}
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught) { throw 'Expected a terminating refusal, but the operation succeeded.' }
    if ($caught -notmatch $Pattern) { throw "Unexpected refusal: $caught" }
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        $script:DeploymentPasses++
        Write-Host "PASS $Name"
    } catch {
        $script:DeploymentFailures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "FAIL ${Name}: $($_.Exception.Message)"
    }
}
function Write-TestMarkerData($Data) {
    [IO.File]::WriteAllText($ctx.MarkerPath, ($Data | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
}
function Read-TestXml([string]$Text) {
    $doc = [xml]$Text
    $ns = New-Object Xml.XmlNamespaceManager $doc.NameTable
    $ns.AddNamespace('t', $CapsTaskNamespace)
    return [pscustomobject]@{ Doc = $doc; Ns = $ns }
}

# A hard guard against accidentally invoking the real Task Scheduler from a test.
function Get-CapsTaskFolder { throw 'TEST GUARD: real Task Scheduler access is forbidden.' }

# PowerShell cannot mock a static .NET property directly. Clone only these four
# already-loaded helpers, replacing their Registry.CurrentUser boundary with an
# in-memory equivalent. Their ownership/quoting/restore logic stays unchanged.
# This also prevents a broken refusal check from touching the real registry.
$script:TestRegistryValues = @{}
$script:TestRegistryKey = New-Object PSObject
$script:TestRegistryKey | Add-Member ScriptMethod GetValue {
    param($Name, $Default, $Options)
    if ($script:TestRegistryValues.ContainsKey($Name)) { return $script:TestRegistryValues[$Name].Data }
    return $Default
}
$script:TestRegistryKey | Add-Member ScriptMethod GetValueKind {
    param($Name)
    return $script:TestRegistryValues[$Name].Kind
}
$script:TestRegistryKey | Add-Member ScriptMethod SetValue {
    param($Name, $Data, $Kind)
    $script:TestRegistryValues[$Name] = [pscustomobject]@{ Data = $Data; Kind = $Kind }
}
$script:TestRegistryKey | Add-Member ScriptMethod DeleteValue {
    param($Name, $ThrowIfMissing)
    $script:TestRegistryValues.Remove($Name)
}
$script:TestRegistryKey | Add-Member ScriptMethod Close {}
$script:TestRegistryRoot = New-Object PSObject
$script:TestRegistryRoot | Add-Member ScriptMethod OpenSubKey {
    param($Name, $Writable)
    if ($Name -cne $script:CapsRunKeyPath) { throw 'Unexpected registry path in test.' }
    return $script:TestRegistryKey
}
$script:TestRegistryRoot | Add-Member ScriptMethod CreateSubKey {
    param($Name)
    if ($Name -cne $script:CapsRunKeyPath) { throw 'Unexpected registry path in test.' }
    return $script:TestRegistryKey
}
function Get-TestRegistryRoot { return $script:TestRegistryRoot }
foreach ($helperName in @('Get-CapsRunValueInfo', 'Set-CapsRunValue', 'Restore-CapsRunValue', 'Remove-CapsOwnedRunValue')) {
    $originalBody = (Get-Item -LiteralPath ('Function:\' + $helperName)).ScriptBlock.ToString()
    $mockedBody = $originalBody.Replace('[Microsoft.Win32.Registry]::CurrentUser', '(Get-TestRegistryRoot)')
    if ($mockedBody -ceq $originalBody -or $mockedBody -match '\[Microsoft\.Win32\.Registry\]') {
        throw "Registry test isolation needs updating for $helperName; no helper will be called."
    }
    Set-Item -LiteralPath ('Function:\' + $helperName) -Value ([scriptblock]::Create($mockedBody))
}

$resolvedWorkRoot = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
$caseName = 'case-' + [guid]::NewGuid().ToString('N')
$testRoot = Join-Path $resolvedWorkRoot $caseName
[void][IO.Directory]::CreateDirectory($testRoot)
# Construct Unicode independently of the source file encoding used by PS 5.1.
$korean = -join @([char]0xD14C, [char]0xC2A4, [char]0xD2B8, ' ', [char]0xC0AC, [char]0xC6A9, [char]0xC790)
$baseDir = Join-Path $testRoot ($korean + ' & [profile]')
$installDir = Join-Path $baseDir 'CapsLockHangul'
[void][IO.Directory]::CreateDirectory($installDir)
$ctx = [pscustomobject]@{
    BaseDir = $baseDir
    InstallDir = $installDir
    ExePath = Join-Path $installDir 'CapsLockHangul.exe'
    MarkerPath = Join-Path $installDir 'install.json'
    LogDir = Join-Path $installDir 'logs'
    Sid = 'S-1-5-21-100-200-300-1001'
    UserName = 'TEST\' + $korean + ' & reviewer'
    TaskName = 'CapsLockHangul-S-1-5-21-100-200-300-1001'
    RunValueName = 'CapsLockHangul'
    ScriptDir = Join-Path $testRoot 'repository'
    IsInstalledCopy = $false
}
try {
    Test-Case 'exact installation boundary accepts spaces and Unicode' {
        Assert-CapsInstallDir $ctx
        Assert-True (Test-CapsSamePath $ctx.InstallDir ($ctx.InstallDir + '\')) 'Trailing slash changed path identity.'
        Assert-True (-not (Test-CapsSamePath '' $ctx.InstallDir)) 'Blank path was accepted.'
    }
    Test-Case 'installation boundary rejects sibling and nested destinations' {
        $bad = $ctx.PSObject.Copy()
        $bad.InstallDir = Join-Path $baseDir 'OtherApp'
        Assert-Throws { Assert-CapsInstallDir $bad } 'Unexpected install folder'
        $bad.InstallDir = Join-Path (Join-Path $baseDir 'nested') 'CapsLockHangul'
        Assert-Throws { Assert-CapsInstallDir $bad } 'not directly under'
    }
    Test-Case 'missing marker is distinct from invalid marker' {
        Assert-Equal 'Missing' (Read-CapsMarker $ctx).State 'Missing marker classification failed.'
        [IO.File]::WriteAllText($ctx.MarkerPath, '{ broken json')
        Assert-Equal 'Invalid' (Read-CapsMarker $ctx).State 'Malformed marker was accepted.'
    }
    foreach ($arguments in @('', '--dedicated-hold')) {
        Test-Case "UTF8 marker round trip and saved arguments [$arguments]" {
            Write-CapsMarker $ctx 'Task' $arguments
            $read = Read-CapsMarker $ctx
            Assert-Equal 'Valid' $read.State 'UTF8 marker rejected.'
            Assert-Equal $ctx.UserName $read.Data.userName 'Unicode username changed.'
            Assert-Equal $ctx.InstallDir $read.Data.installDir 'Unicode path changed.'
            Assert-Equal $arguments (Get-CapsConfiguredArguments $ctx) 'Launch arguments changed.'
        }
    }
    foreach ($field in @('product', 'userSid', 'installDir')) {
        Test-Case "foreign marker rejected [$field]" {
            Write-CapsMarker $ctx 'Task'
            $data = (Read-CapsMarker $ctx).Data
            $data.$field = if ($field -eq 'installDir') { Join-Path $testRoot 'foreign' } else { 'foreign' }
            Write-TestMarkerData $data
            Assert-Equal 'Invalid' (Read-CapsMarker $ctx).State 'Foreign ownership accepted.'
        }
    }
    Test-Case 'legacy marker without launchArguments keeps default behavior' {
        Write-CapsMarker $ctx 'Task' '--dedicated-hold'
        $data = (Read-CapsMarker $ctx).Data
        $data.PSObject.Properties.Remove('launchArguments')
        Write-TestMarkerData $data
        Assert-Equal '' (Get-CapsConfiguredArguments $ctx) 'Legacy marker did not default safely.'
    }
    Test-Case 'unsupported saved arguments cannot become a launch command' {
        Write-CapsMarker $ctx 'Task' '--stop'
        Assert-Throws { Get-CapsConfiguredArguments $ctx } 'Unsupported launch arguments'
    }
    Test-Case 'retained log ownership marker permits future installation checks' {
        [void][IO.Directory]::CreateDirectory($ctx.LogDir)
        [IO.File]::WriteAllText((Join-Path $ctx.LogDir 'test.log'), 'test only')
        Write-CapsMarker $ctx 'Uninstalled'
        Assert-CapsInstallDir $ctx
        Assert-Equal 'Valid' (Read-CapsMarker $ctx).State 'Retained logs lost their ownership marker.'
    }

    foreach ($arguments in @('', '--dedicated-hold')) {
        Test-Case "task XML preserves login behavior and arguments [$arguments]" {
            $xml = New-CapsTaskXml $ctx $arguments
            $parsed = Read-TestXml $xml
            $checks = @{
                '/t:Task/t:Triggers/t:LogonTrigger/t:UserId' = $ctx.Sid
                '/t:Task/t:Principals/t:Principal/t:UserId' = $ctx.Sid
                '/t:Task/t:Principals/t:Principal/t:LogonType' = 'InteractiveToken'
                '/t:Task/t:Principals/t:Principal/t:RunLevel' = 'LeastPrivilege'
                '/t:Task/t:Settings/t:MultipleInstancesPolicy' = 'IgnoreNew'
                '/t:Task/t:Settings/t:DisallowStartIfOnBatteries' = 'false'
                '/t:Task/t:Settings/t:StopIfGoingOnBatteries' = 'false'
                '/t:Task/t:Settings/t:ExecutionTimeLimit' = 'PT0S'
                '/t:Task/t:Actions/t:Exec/t:Command' = $ctx.ExePath
                '/t:Task/t:Actions/t:Exec/t:Arguments' = $arguments
                '/t:Task/t:Actions/t:Exec/t:WorkingDirectory' = $ctx.InstallDir
            }
            foreach ($xpath in $checks.Keys) {
                $node = $parsed.Doc.SelectSingleNode($xpath, $parsed.Ns)
                Assert-True ($null -ne $node) "Missing task XML element: $xpath"
                Assert-Equal $checks[$xpath] $node.InnerText "Wrong task setting: $xpath"
            }
            Assert-True ([string]::IsNullOrEmpty((Get-CapsTaskForeignReason $ctx $xml))) 'Generated task was classified as foreign.'
        }
    }
    foreach ($case in @('foreign-exe', 'foreign-user', 'extra-action', 'unsupported-arguments', 'wrong-context', 'extra-principal', 'missing-command')) {
        Test-Case "foreign task rejected [$case]" {
            $parsed = Read-TestXml (New-CapsTaskXml $ctx '--dedicated-hold')
            switch ($case) {
                'foreign-exe' { $parsed.Doc.SelectSingleNode('//t:Exec/t:Command', $parsed.Ns).InnerText = 'C:\Foreign\App.exe' }
                'foreign-user' { $parsed.Doc.SelectSingleNode('//t:Principal/t:UserId', $parsed.Ns).InnerText = 'S-1-5-18' }
                'extra-action' {
                    $node = $parsed.Doc.SelectSingleNode('//t:Exec', $parsed.Ns)
                    [void]$node.ParentNode.AppendChild($node.CloneNode($true))
                }
                'unsupported-arguments' { $parsed.Doc.SelectSingleNode('//t:Exec/t:Arguments', $parsed.Ns).InnerText = '--stop' }
                'wrong-context' { $parsed.Doc.SelectSingleNode('/t:Task/t:Actions', $parsed.Ns).SetAttribute('Context', 'OtherPrincipal') }
                'extra-principal' {
                    $node = $parsed.Doc.SelectSingleNode('//t:Principal', $parsed.Ns)
                    $copy = $node.CloneNode($true)
                    $copy.SetAttribute('id', 'OtherPrincipal')
                    $copy.SelectSingleNode('t:UserId', $parsed.Ns).InnerText = 'S-1-5-18'
                    [void]$node.ParentNode.AppendChild($copy)
                }
                'missing-command' {
                    $node = $parsed.Doc.SelectSingleNode('//t:Exec/t:Command', $parsed.Ns)
                    [void]$node.ParentNode.RemoveChild($node)
                }
            }
            Assert-True (-not [string]::IsNullOrEmpty((Get-CapsTaskForeignReason $ctx $parsed.Doc.OuterXml))) 'Foreign task was classified as owned.'
        }
    }
    Test-Case 'unrelated task is refused before any deletion request' {
        function Get-CapsTaskInfo($Ctx) { return [pscustomobject]@{ Exists = $true; Owned = $false; Reason = 'foreign fixture' } }
        Assert-Throws { Remove-CapsOwnedTask $ctx } 'Not removing scheduled task.*foreign fixture'
    }
    Test-Case 'foreign Run value cannot be overwritten or removed' {
        function Get-CapsRunValueInfo($Ctx) { return [pscustomobject]@{ Exists = $true; Owned = $false; Data = 'foreign fixture' } }
        Assert-Throws { Set-CapsRunValue $ctx '--dedicated-hold' } 'foreign data; not overwriting'
        Assert-Throws { Remove-CapsOwnedRunValue $ctx } 'Not removing HKCU Run value'
    }
    foreach ($arguments in @('', '--dedicated-hold')) {
        Test-Case "Run fallback preserves quoting and is recognized as owned [$arguments]" {
            $script:TestRegistryValues = @{}
            $script:TestRegistryKey.SetValue('UnrelatedApp', 'keep this command', [Microsoft.Win32.RegistryValueKind]::String)
            Set-CapsRunValue $ctx $arguments
            $info = Get-CapsRunValueInfo $ctx
            $expected = '"' + $ctx.ExePath + '"'
            if ($arguments) { $expected += ' ' + $arguments }
            Assert-True $info.Owned 'Our fallback command was classified as foreign.'
            Assert-Equal $expected $info.Data 'Fallback lost path quoting or launch arguments.'
            Remove-CapsOwnedRunValue $ctx
            Assert-True (-not (Get-CapsRunValueInfo $ctx).Exists) 'Owned fallback was not removed.'
            Assert-Equal 'keep this command' $script:TestRegistryValues['UnrelatedApp'].Data 'Unrelated startup value changed.'
        }
    }
    Test-Case 'Run ownership excludes other executables, switches, and registry types' {
        foreach ($value in @('"C:\Foreign\App.exe"', ('"' + $ctx.ExePath + '" --stop'), 123)) {
            $script:TestRegistryValues = @{}
            $script:TestRegistryKey.SetValue($ctx.RunValueName, $value, [Microsoft.Win32.RegistryValueKind]::String)
            Assert-True (-not (Get-CapsRunValueInfo $ctx).Owned) 'Foreign Run value was classified as owned.'
            Assert-Throws { Set-CapsRunValue $ctx } 'foreign data; not overwriting'
            Assert-Equal $value $script:TestRegistryValues[$ctx.RunValueName].Data 'Foreign Run value was overwritten.'
        }
    }
    Test-Case 'Run rollback restores exact previous data and registry value kind' {
        $script:TestRegistryValues = @{}
        $previous = '"' + $ctx.ExePath + '"'
        $script:TestRegistryKey.SetValue($ctx.RunValueName, $previous, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $before = Get-CapsRunValueInfo $ctx
        Set-CapsRunValue $ctx '--dedicated-hold'
        Restore-CapsRunValue $ctx $before
        $after = Get-CapsRunValueInfo $ctx
        Assert-Equal $before.Data $after.Data 'Rollback changed the old startup command.'
        Assert-Equal $before.Kind $after.Kind 'Rollback changed the old registry value kind.'
    }
    Test-Case 'Run rollback removes only a newly-created value' {
        $script:TestRegistryValues = @{}
        $script:TestRegistryKey.SetValue('UnrelatedApp', 'keep', [Microsoft.Win32.RegistryValueKind]::String)
        $before = Get-CapsRunValueInfo $ctx
        Set-CapsRunValue $ctx '--dedicated-hold'
        Restore-CapsRunValue $ctx $before
        Assert-True (-not (Get-CapsRunValueInfo $ctx).Exists) 'New value survived rollback.'
        Assert-Equal 'keep' $script:TestRegistryValues['UnrelatedApp'].Data 'Rollback removed an unrelated value.'
    }
    Test-Case 'unknown launch options are rejected before external operations' {
        function Start-Process { throw 'TEST GUARD: an invalid launch reached Start-Process.' }
        function Get-CapsRunValueInfo { throw 'TEST GUARD: invalid arguments reached registry lookup.' }
        foreach ($bad in @('--stop', '--dedicated-hold --stop', '; whoami', ' --dedicated-hold')) {
            Assert-Throws { New-CapsTaskXml $ctx $bad } 'Unsupported launch arguments'
            Assert-Throws { Start-CapsProcess $ctx.ExePath $bad } 'Unsupported launch arguments'
            Assert-Throws { Set-CapsRunValue $ctx $bad } 'Unsupported launch arguments'
        }
    }
    foreach ($arguments in @('', '--dedicated-hold')) {
        Test-Case "manual launch stays hidden and matches startup arguments [$arguments]" {
            $script:CapturedStart = $null
            function Start-Process {
                param($FilePath, $WorkingDirectory, $WindowStyle, $ArgumentList)
                $script:CapturedStart = @{
                    FilePath = $FilePath; WorkingDirectory = $WorkingDirectory
                    WindowStyle = $WindowStyle; Arguments = [string]$ArgumentList
                }
            }
            Start-CapsProcess $ctx.ExePath $arguments
            Assert-Equal $ctx.ExePath $script:CapturedStart.FilePath 'Launch path changed.'
            Assert-Equal $ctx.InstallDir $script:CapturedStart.WorkingDirectory 'Working directory changed.'
            Assert-Equal 'Hidden' $script:CapturedStart.WindowStyle 'Background launch is not hidden.'
            Assert-Equal $arguments $script:CapturedStart.Arguments 'Manual launch disagrees with task arguments.'
        }
    }
    foreach ($wantRunning in @($true, $false)) {
        Test-Case "readiness wait tolerates transition states [running=$wantRunning]" {
            $script:StatusQueue = New-Object 'System.Collections.Generic.Queue[int]'
            $script:StatusQueue.Enqueue(4)
            $script:StatusQueue.Enqueue(4)
            $script:StatusQueue.Enqueue($(if ($wantRunning) { 0 } else { 3 }))
            function Invoke-CapsExe($Exe, $Arguments, $TimeoutSec) {
                Assert-Equal '--status' ($Arguments -join ' ') 'Wait queried the wrong helper.'
                return $script:StatusQueue.Dequeue()
            }
            function Start-Sleep { param($Milliseconds) }
            Assert-Equal $true (Wait-CapsRunning $ctx.ExePath $wantRunning 15) 'Transition did not reach the requested state.'
            Assert-Equal 0 $script:StatusQueue.Count 'Wait returned before observing its terminal state.'
        }
        Test-Case "transition state times out without false success [running=$wantRunning]" {
            function Invoke-CapsExe($Exe, $Arguments, $TimeoutSec) { return 4 }
            function Start-Sleep { param($Milliseconds) }
            Assert-Equal $false (Wait-CapsRunning $ctx.ExePath $wantRunning 0) 'Starting/stopping was misreported as a terminal state.'
        }
        Test-Case "unknown helper status fails immediately [running=$wantRunning]" {
            function Invoke-CapsExe($Exe, $Arguments, $TimeoutSec) { return 7 }
            function Start-Sleep { throw 'TEST GUARD: unknown helper status was retried.' }
            Assert-Throws { Wait-CapsRunning $ctx.ExePath $wantRunning 15 } 'Unexpected --status exit code 7'
        }
    }
    Test-Case 'running query returns stable states without waiting' {
        function Wait-CapsRunning { throw 'TEST GUARD: a stable state entered transition polling.' }
        function Invoke-CapsExe($Exe, $Arguments, $TimeoutSec) { return $script:StableStatus }
        $script:StableStatus = 0
        Assert-Equal $true (Test-CapsRunning $ctx.ExePath) 'Ready process not recognized.'
        $script:StableStatus = 3
        Assert-Equal $false (Test-CapsRunning $ctx.ExePath) 'Absent process not recognized.'
    }
    foreach ($becomesReady in @($true, $false)) {
        Test-Case "running query resolves transition with a bounded wait [ready=$becomesReady]" {
            $script:CapturedWait = $null
            function Invoke-CapsExe($Exe, $Arguments, $TimeoutSec) { return 4 }
            function Wait-CapsRunning($Exe, $Running, $TimeoutSec) {
                $script:CapturedWait = [pscustomobject]@{ Exe = $Exe; Running = $Running; Timeout = $TimeoutSec }
                return $becomesReady
            }
            if ($becomesReady) {
                Assert-Equal $true (Test-CapsRunning $ctx.ExePath) 'Ready result was lost after transition.'
            } else {
                Assert-Throws { Test-CapsRunning $ctx.ExePath } 'ready|starting|timeout|15'
            }
            Assert-True ($null -ne $script:CapturedWait) 'Transition never entered the bounded wait.'
            Assert-Equal $ctx.ExePath $script:CapturedWait.Exe 'Wait targeted a different executable.'
            Assert-Equal $true $script:CapturedWait.Running 'Query waited for absence rather than readiness.'
            Assert-Equal 15 $script:CapturedWait.Timeout 'Transition wait has the wrong timeout.'
        }
    }
    Test-Case 'owned file deletion preserves unrelated neighbors and rejects traversal' {
        $owned = Join-Path $ctx.InstallDir 'owned.txt'
        $neighbor = Join-Path $ctx.InstallDir 'keep.txt'
        [IO.File]::WriteAllText($owned, 'owned fixture')
        [IO.File]::WriteAllText($neighbor, 'unrelated fixture')
        Remove-CapsOwnedFile $ctx.InstallDir 'owned.txt'
        Assert-True (-not (Test-Path -LiteralPath $owned)) 'Owned file was not removed.'
        Assert-True (Test-Path -LiteralPath $neighbor) 'Unrelated file was removed.'
        Assert-Throws { Remove-CapsOwnedFile $ctx.InstallDir '..\keep.txt' } 'suspicious file name'
        Assert-Equal $false (Remove-CapsDirIfEmpty $ctx.InstallDir) 'Nonempty directory was removed.'
    }
    Test-Case 'reparse points are refused without following or deleting targets' {
        $target = Join-Path $ctx.InstallDir 'link-fixture.txt'
        [IO.File]::WriteAllText($target, 'must survive')
        function Test-CapsReparsePoint([string]$Path) { return $true }
        Assert-Throws { Assert-CapsInstallDir $ctx } 'reparse point'
        Assert-Throws { Remove-CapsOwnedFile $ctx.InstallDir 'link-fixture.txt' } 'reparse point'
        Assert-Equal 'must survive' ([IO.File]::ReadAllText($target)) 'Refused target was changed.'
    }
} finally {
    # Validate the actual absolute deletion target before any recursive cleanup.
    $cleanupRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    if (-not $cleanupRoot.StartsWith($resolvedWorkRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $cleanupRoot) -cne $caseName -or $caseName -notmatch '^case-[0-9a-f]{32}$') {
        throw "Unsafe test cleanup target: $cleanupRoot"
    }
    if (Test-Path -LiteralPath $cleanupRoot) { Remove-Item -LiteralPath $cleanupRoot -Recurse -Force }
}

Write-Host "Deployment tests: $script:DeploymentPasses passed, $($script:DeploymentFailures.Count) failed."
if ($script:DeploymentFailures.Count -gt 0) {
    throw ($script:DeploymentFailures -join [Environment]::NewLine)
}
