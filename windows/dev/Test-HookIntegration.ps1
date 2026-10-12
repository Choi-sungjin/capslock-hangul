# A disposable foreground-only test window appears for several seconds.
# No installation, startup registration, registry edit, or hardware input capture.
[CmdletBinding()]
param([string]$ReportPath)
$ErrorActionPreference = 'Stop'
$windowsRoot = Split-Path -Parent $PSScriptRoot
$binRoot = Join-Path $windowsRoot 'bin'
$corePath = Join-Path $windowsRoot 'src\CapsLockHangul.cs'
$harnessPath = Join-Path $PSScriptRoot 'HookIntegration.cs'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework C# compiler was not found.' }
if (Get-Process -Name 'CapsLockHangul' -ErrorAction SilentlyContinue) {
    throw 'Stop the installed remapper before running the isolated hook test.'
}
New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
if (-not $ReportPath) { $ReportPath = Join-Path $binRoot 'hook-integration-result.json' }
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReportPath) | Out-Null
$exePath = Join-Path $binRoot 'HookIntegration.exe'
# This symbol is never defined by the production build. It only admits the
# harness's unique dwExtraInfo tag as simulated hardware to the actual hook.
& $compiler /nologo /target:exe /platform:anycpu /define:HOOK_INTEGRATION_TEST /main:HookIntegration /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll "/out:$exePath" $corePath $harnessPath
if ($LASTEXITCODE -ne 0) { throw "Integration compilation failed ($LASTEXITCODE)." }
$stdoutPath = Join-Path $binRoot 'hook-integration.stdout.txt'
$stderrPath = Join-Path $binRoot 'hook-integration.stderr.txt'
$probeProcess = Start-Process -FilePath $exePath -ArgumentList ('"' + $ReportPath + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
if (-not $probeProcess.WaitForExit(9000)) {
    Stop-Process -Id $probeProcess.Id -ErrorAction SilentlyContinue
    throw 'Integration probe exceeded the nine-second process bound.'
}
$probeProcess.Refresh()
if (-not (Test-Path -LiteralPath $ReportPath)) { throw "No integration report. See $stderrPath" }
$rows = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
$completion = @($rows | Where-Object { $_.complete })
$tests = @($rows | Where-Object { $_.test })
$failed = @($tests | Where-Object { -not $_.pass })
if ($probeProcess.ExitCode -ne 0 -or $completion.Count -ne 1 -or $failed.Count -ne 0 -or -not $completion[0].complete.capsRestored -or -not $completion[0].complete.altReleased) {
    $rows | ConvertTo-Json -Depth 8
    throw "Integration test failed. Report: $ReportPath"
}
[pscustomobject]@{
    Passed = $tests.Count
    Failed = $failed.Count
    ElapsedMs = $completion[0].complete.elapsedMs
    SourceSHA256 = (Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash
    Report = $ReportPath
    Scope = 'Actual Win32 hook and SendInput with compile-only synthetic-input seam; no physical keyboard or reboot validation'
}
