<#
.SYNOPSIS
    N-01 adversarial regression: uses the REAL public wrapper and the REAL
    downstream parameter parser. DryRun everywhere; no downloads, no server.
#>
[CmdletBinding()]
param()

$RepoRoot = Split-Path -Parent $PSScriptRoot
$wrapper = Join-Path $RepoRoot 'Install-LocalAI.ps1'

$script:Passed = 0
$script:Failed = 0
$script:SideEffects = 0

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        [int]$ExpectExit = 0,
        [string]$MustContain = '',
        [switch]$RootMustNotExist,
        [string]$InjectedRoot = ''
    )
    $psiArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper) + $Arguments
    $outFile = Join-Path $env:TEMP 'lai-inj-out.txt'
    $errFile = Join-Path $env:TEMP 'lai-inj-err.txt'
    $p = Start-Process -FilePath 'powershell' -ArgumentList $psiArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $code = $p.ExitCode
    if ($null -eq $code) { $code = -1 }
    $out = if (Test-Path $outFile) { [IO.File]::ReadAllText($outFile) } else { '' }
    $ok = ($code -eq $ExpectExit)
    if ($MustContain -and ($out -notmatch [regex]::Escape($MustContain))) { $ok = $false }
    if ($RootMustNotExist -and (Test-Path -LiteralPath $InjectedRoot)) { $ok = $false; $script:SideEffects++ }
    if ($ok) {
        $script:Passed++
        Write-Host ("  PASS  {0} (exit {1})" -f $Name, $code) -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host ("  FAIL  {0} (exit {1}, expected {2})" -f $Name, $code, $ExpectExit) -ForegroundColor Red
        if ($RootMustNotExist) { Write-Host ("        INJECTED ROOT CREATED: {0}" -f $InjectedRoot) -ForegroundColor Red }
    }
}

$injRoot1 = 'C:\lai-inj-probe-root'
$injRoot2 = 'C:\lai-inj-probe-root-2'
Remove-Item $injRoot1, $injRoot2 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '== normal values ==' -ForegroundColor Cyan
Test-Case 'normal -Model' @('-DryRun', '-Model', 'huihui-nex-q4') 0 'Huihui Nex N2 Mini'
Test-Case 'normal -Category fast' @('-DryRun', '-Category', 'fast') 0 'Qwen3.8'
Test-Case 'explicit -Port 18150' @('-DryRun', '-Port', '18150') 0 '18150'
Test-Case 'model with spaces' @('-DryRun', '-Model', 'qwen fast q4') 1

Write-Host ''
Write-Host '== auditor quote-injection reproductions ==' -ForegroundColor Cyan
Test-Case 'quote -> Port injection' @('-DryRun', '-Model', 'huihui-nex-q4" -Port "18151') 1 -RootMustNotExist -InjectedRoot $injRoot1
Test-Case 'quote -> Root injection' @('-DryRun', '-Model', 'huihui-nex-q4" -Root "C:\lai-inj-probe-root') 1 -RootMustNotExist -InjectedRoot $injRoot1
Test-Case 'category -> Root injection' @('-DryRun', '-Category', 'fast" -Root "C:\lai-inj-probe-root-2') 1 -RootMustNotExist -InjectedRoot $injRoot2
Test-Case 'category -> Port injection' @('-DryRun', '-Category', 'fast" -Port "18152') 1
Test-Case 'quote -> Yes injection' @('-DryRun', '-Model', 'huihui-nex-q4" -Yes') 1
Test-Case 'quote -> RemoveModels injection' @('-DryRun', '-Model', 'huihui-nex-q4" -RemoveModels') 1

Write-Host ''
Write-Host '== command-like data must stay data ==' -ForegroundColor Cyan
Test-Case 'semicolon data' @('-DryRun', '-Model', '; Write-Host INJECTED') 1
Test-Case 'ampersand data' @('-DryRun', '-Model', '& whoami') 1
Test-Case 'subexpression data' @('-DryRun', '-Model', '$(Get-Location)') 1
Test-Case 'backtick + quote data' @('-DryRun', '-Model', '`" -Yes') 1
Test-Case 'single+double quote combo' @('-DryRun', '-Model', "it`s a 'test' `"case`"") 1
Test-Case 'leading-dash data' @('-DryRun', '-Model', '-Yes') 1
Test-Case 'double-dash-looking data' @('-DryRun', '-Model', '--Root') 1

Write-Host ''
Write-Host ("  passed: {0}  failed: {1}  side effects: {2}" -f $script:Passed, $script:Failed, $script:SideEffects)
exit $(if ($script:Failed -gt 0) { 1 } else { 0 })
