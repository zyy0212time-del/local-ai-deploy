# LocalAIDeploy — runtime abstraction.
#
# v0.1 ships exactly ONE runtime implementation (llama.cpp). The interface below
# exists so that a future backend (e.g. FreeToken) can be added without
# touching installer / model / profile / download / process logic.
#
# A runtime module must export these functions, all prefixed with the runtime id:
#   <id>.Test-Installed
#   <id>.Install-              (idempotent, returns path info)
#   <id>.Get-CommandArguments  (plan -> argument array)
#   <id>.Start-Server          (plan -> process)
#   <id>.Get-HealthUrl         (plan -> url)
#   <id>.Get-Version

$script:Registry = @{}

function Register-LaiRuntime {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$ModuleName,
        [string]$Description = ''
    )
    $script:Registry[$Id] = @{ id = $Id; module = $ModuleName; description = $Description }
}

function Get-LaiRuntime {
    param([Parameter(Mandatory)][string]$Id)
    if (-not $script:Registry.ContainsKey($Id)) { return $null }
    return $script:Registry[$Id]
}

function Get-LaiRuntimeIds {
    return @($script:Registry.Keys)
}

function Invoke-LaiRuntime {
    <#
    Dispatches to a registered runtime function:
      Invoke-LaiRuntime -Id llama-cpp -Operation Test-Installed -Arguments @(...)
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Operation,
        [object[]]$Arguments = @()
    )
    $rt = Get-LaiRuntime -Id $Id
    if (-not $rt) { throw "runtime not registered: $Id" }
    $fn = "{0}.{1}" -f $Id.Replace('-', ''), $Operation
    $cmd = Get-Command -Name $fn -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "runtime $Id does not implement $Operation" }
    return (& $cmd @Arguments)
}

Export-ModuleMember -Function Register-LaiRuntime, Get-LaiRuntime,
                              Get-LaiRuntimeIds, Invoke-LaiRuntime
