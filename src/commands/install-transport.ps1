<#
.SYNOPSIS
    Project-owned child transport for Install-LocalAI.ps1.

.DESCRIPTION
    Receives the Base64 payload produced by WrapperTransport, decodes it and
    invokes `local-ai.ps1 install` through real PowerShell parameter
    splatting. The exit code of local-ai.ps1 becomes this process's exit code
    so the wrapper can propagate it.

    The payload is inert Base64 data: user-supplied Model/Category values
    never appear in a command line as syntax.
#>
param([Parameter(Mandatory)][string]$Payload)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# src\commands -> src -> repo root
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path $here 'WrapperTransport.psm1') -Force

$splat = ConvertFrom-LaiPayloadToSplat -Payload $Payload
& (Join-Path $repoRoot 'local-ai.ps1') install @splat
exit $LASTEXITCODE
