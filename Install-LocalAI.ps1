<#
.SYNOPSIS
    One-click entry point for LocalAIDeploy v0.1.

.DESCRIPTION
    Runs the installer with sane defaults. This script does NOT require
    disabling PowerShell execution policy: if direct execution is blocked,
    run it with:

        powershell -ExecutionPolicy Bypass -File .\Install-LocalAI.ps1

    That is a per-process override, not a machine-wide policy change.

    Parameters are forwarded to local-ai.ps1 as real PowerShell named
    parameters (never GNU-style "--x"), and the child exit code is propagated
    so a failed invocation can never look like success.

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

function Exit-Lai {
    param([int]$Code)
    exit $Code
}

if (-not (Test-Path -LiteralPath $cli)) {
    Write-Host "local-ai.ps1 not found next to this script." -ForegroundColor Red
    Exit-Lai 1
}

# build a real PowerShell argument list for the child process
$childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli, 'install')
if ($DryRun) { $childArgs += '-DryRun' }
if ($Yes) { $childArgs += '-Yes' }
if ($Model) { $childArgs += @('-Model', ('"{0}"' -f $Model)) }
if ($Category) { $childArgs += @('-Category', ('"{0}"' -f $Category)) }
if ($Port -gt 0) { $childArgs += @('-Port', [string]$Port) }

$proc = $null
try {
    $proc = Start-Process -FilePath 'powershell' -ArgumentList $childArgs -NoNewWindow -Wait -PassThru
} catch {
    Write-Host ("failed to start installer: " + $_.Exception.Message) -ForegroundColor Red
    Exit-Lai 1
}

if ($null -eq $proc) {
    Write-Host "installer did not start." -ForegroundColor Red
    Exit-Lai 1
}

$code = $proc.ExitCode
if ($null -eq $code) {
    # no usable native exit code at all → never report success
    $code = 1
}
Exit-Lai ([int]$code)
