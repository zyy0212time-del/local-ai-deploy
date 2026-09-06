<#
.SYNOPSIS
    One-click entry point for LocalAIDeploy v0.1.

.DESCRIPTION
    Runs the installer with sane defaults. This script does NOT require
    disabling PowerShell execution policy: if direct execution is blocked,
    run it with:

        powershell -ExecutionPolicy Bypass -File .\Install-LocalAI.ps1

    That is a per-process override, not a machine-wide policy change.

    Add -DryRun to preview without downloading or changing anything.
#>
param(
    [switch]$DryRun,
    [string]$Model,
    [string]$Category,
    [int]$Port = 0,
    [switch]$Yes
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cli = Join-Path $here 'local-ai.ps1'

if (-not (Test-Path -LiteralPath $cli)) {
    Write-Host "local-ai.ps1 not found next to this script." -ForegroundColor Red
    exit 1
}

$argv = @('install')
if ($DryRun) { $argv += '--DryRun' }
if ($Model) { $argv += @('--Model', $Model) }
if ($Category) { $argv += @('--Category', $Category) }
if ($Port -gt 0) { $argv += @('--Port', $Port) }
if ($Yes) { $argv += '--Yes' }

& $cli @argv
exit $LASTEXITCODE
