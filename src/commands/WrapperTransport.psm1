# LocalAIDeploy — wrapper argument transport (F-03D / N-01).
#
# Raw user-supplied values (Model / Category) must NEVER participate in
# reconstructing a child powershell.exe command line: PS 5.1 Start-Process
# argument reconstruction allows an embedded '"' to escape a data argument
# and create extra switches (N-01).
#
# Transport: typed values -> JSON -> UTF-8 Base64. The Base64 payload contains
# only [A-Za-z0-9+/=] and is therefore inert command-line data. The child
# decodes it and binds the values through real PowerShell parameter
# splatting — the values are never re-parsed as command-line syntax.

function ConvertTo-LaiPayload {
    param(
        [bool]$DryRun = $false,
        [bool]$Yes = $false,
        [string]$Model = '',
        [string]$Category = '',
        [int]$Port = 0
    )
    $obj = [ordered]@{
        DryRun   = [bool]$DryRun
        Yes      = [bool]$Yes
        Model    = [string]$Model
        Category = [string]$Category
        Port     = [int]$Port
    }
    $json = $obj | ConvertTo-Json -Depth 3 -Compress
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function ConvertFrom-LaiPayload {
    param([Parameter(Mandatory)][string]$Payload)
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload))
    return ($json | ConvertFrom-Json)
}

function ConvertFrom-LaiPayloadToSplat {
    <#
    Rebuilds the downstream parameter hashtable through real PowerShell
    binding. Only the fixed, wrapper-declared parameter set can ever appear —
    data values cannot mint new parameters.
    #>
    param([Parameter(Mandatory)][string]$Payload)
    $p = ConvertFrom-LaiPayload -Payload $Payload
    $splat = @{ }
    if ($p.DryRun) { $splat['DryRun'] = $true }
    if ($p.Yes) { $splat['Yes'] = $true }
    if ($p.Model) { $splat['Model'] = [string]$p.Model }
    if ($p.Category) { $splat['Category'] = [string]$p.Category }
    if ($p.Port -and [int]$p.Port -gt 0) { $splat['Port'] = [int]$p.Port }
    return $splat
}

Export-ModuleMember -Function ConvertTo-LaiPayload, ConvertFrom-LaiPayload,
                              ConvertFrom-LaiPayloadToSplat
