<#
.SYNOPSIS
    One-click entry point for LocalAIDeploy v0.1.

.DESCRIPTION
    Runs the installer with sane defaults. This script does NOT require
    disabling PowerShell execution policy: if direct execution is blocked,
    run it with:

        powershell -ExecutionPolicy Bypass -File .\Install-LocalAI.ps1

    That is a per-process override, not a machine-wide policy change.

    Parameters are forwarded to local-ai.ps1 as structured JSON encoded as
    UTF-8 Base64: raw Model/Category values never appear in a child command
    line as syntax (F-03D / N-01). The child exit code is propagated so a
    failed invocation can never look like success.

.EXAMPLE
    .\Install-LocalAI.ps1 -DryRun
    .\Install-LocalAI.ps1
    .\Install-LocalAI.ps1 -Yes -Model qwen-fast-q4
    .\Install-LocalAI.ps1 -DryRun -Port 18150
#>
param(
    [switch]$DryRun,
    [string]$Model,
    [string]$Category,
    [int]$Port = 0,
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cli = Join-Path $here 'local-ai.ps1'
$transport = Join-Path $here 'src\commands\install-transport.ps1'
$transportModule = Join-Path $here 'src\commands\WrapperTransport.psm1'

if (-not (Test-Path -LiteralPath $cli)) {
    Write-Host "local-ai.ps1 not found next to this script." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $transport)) {
    Write-Host "install transport script not found next to this script." -ForegroundColor Red
    exit 1
}

Import-Module $transportModule -Force

# structured payload: user data never touches the child command line as syntax
$payload = ConvertTo-LaiPayload -DryRun:$DryRun -Yes:$Yes -Model $Model -Category $Category -Port $Port

$childArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $transport, '-Payload', $payload
)

$proc = $null
try {
    $proc = Start-Process -FilePath 'powershell' -ArgumentList $childArgs -NoNewWindow -Wait -PassThru
} catch {
    Write-Host ("failed to start installer: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

if ($null -eq $proc) {
    Write-Host "installer did not start." -ForegroundColor Red
    exit 1
}

$code = $proc.ExitCode
if ($null -eq $code) {
    # no usable native exit code at all → never report success
    $code = 1
}
exit ([int]$code)
