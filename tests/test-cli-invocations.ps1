<#
.SYNOPSIS
    Real command invocations (F-02 / F-03 regression).
    Executes the public documented PowerShell commands and records real exit
    codes. No model download, no server launch — every case uses -DryRun or a
    deliberate failure path.

    Run: powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-cli-invocations.ps1
#>
[CmdletBinding()]
param()

$RepoRoot = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $RepoRoot 'local-ai.ps1'
$wrapper = Join-Path $RepoRoot 'Install-LocalAI.ps1'

$script:Passed = 0
$script:Failed = 0

function Invoke-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$ExpectedExit = 0,
        [string]$MustContain = ''
    )
    $psiArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FilePath) + $Arguments
    $p = Start-Process -FilePath 'powershell' -ArgumentList $psiArgs -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput ([IO.Path]::Combine($env:TEMP, 'lai-case-out.txt')) `
        -RedirectStandardError ([IO.Path]::Combine($env:TEMP, 'lai-case-err.txt'))
    $code = $p.ExitCode
    if ($null -eq $code) { $code = -1 }
    $out = ''
    if (Test-Path ([IO.Path]::Combine($env:TEMP, 'lai-case-out.txt'))) {
        $out = [IO.File]::ReadAllText([IO.Path]::Combine($env:TEMP, 'lai-case-out.txt'))
    }
    $ok = ($code -eq $ExpectedExit)
    if ($MustContain -and ($out -notmatch [regex]::Escape($MustContain))) { $ok = $false }
    if ($ok) {
        $script:Passed++
        Write-Host ("  PASS  {0} (exit {1})" -f $Name, $code) -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host ("  FAIL  {0} (exit {1}, expected {2}, contains '{3}': {4})" -f `
            $Name, $code, $ExpectedExit, $MustContain, ($out -match [regex]::Escape($MustContain))) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "== real documented invocations ==" -ForegroundColor Cyan
Invoke-Case -Name 'local-ai install -DryRun' -FilePath $cli -Arguments @('install', '-DryRun') -ExpectedExit 0 -MustContain 'DRY RUN'
Invoke-Case -Name 'local-ai status' -FilePath $cli -Arguments @('status') -ExpectedExit 0
Invoke-Case -Name 'local-ai models' -FilePath $cli -Arguments @('models') -ExpectedExit 0
Invoke-Case -Name 'local-ai profile' -FilePath $cli -Arguments @('profile') -ExpectedExit 0
Invoke-Case -Name 'wrapper default (dry-run avoided: use -DryRun)' -FilePath $wrapper -Arguments @('-DryRun') -ExpectedExit 0 -MustContain 'DRY RUN'

Write-Host ""
Write-Host "== F-03 wrapper parameter forwarding ==" -ForegroundColor Cyan
Invoke-Case -Name 'wrapper -DryRun -Yes' -FilePath $wrapper -Arguments @('-DryRun', '-Yes') -ExpectedExit 0 -MustContain 'DRY RUN'
Invoke-Case -Name 'wrapper -Model qwen-fast-q4' -FilePath $wrapper -Arguments @('-DryRun', '-Model', 'qwen-fast-q4') -ExpectedExit 0 -MustContain 'Qwen3.8'
Invoke-Case -Name 'wrapper -Category fast' -FilePath $wrapper -Arguments @('-DryRun', '-Category', 'fast') -ExpectedExit 0 -MustContain 'Qwen3.8'
Invoke-Case -Name 'wrapper -Port 18150' -FilePath $wrapper -Arguments @('-DryRun', '-Port', '18150') -ExpectedExit 0 -MustContain '18150'

Write-Host ""
Write-Host "== F-03 failure must be nonzero ==" -ForegroundColor Cyan
Invoke-Case -Name 'local-ai install -Category nonexistent' -FilePath $cli -Arguments @('install', '-DryRun', '-Category', 'does-not-exist') -ExpectedExit 1
Invoke-Case -Name 'local-ai bogus-command (invalid parameter)' -FilePath $cli -Arguments @('definitely-not-a-command') -ExpectedExit 1
Invoke-Case -Name 'wrapper -Category nonexistent' -FilePath $wrapper -Arguments @('-DryRun', '-Category', 'does-not-exist') -ExpectedExit 1

Write-Host ""
Write-Host ("  passed: {0}  failed: {1}" -f $script:Passed, $script:Failed)
exit $(if ($script:Failed -gt 0) { 1 } else { 0 })
