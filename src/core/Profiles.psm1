# LocalAIDeploy — hardware profile selection and parameter planning.
# The planner always prefers configurations that LOAD RELIABLY over aggressive
# tuning. Estimates are deliberately coarse: no promised tokens/second.

function Select-LaiProfile {
    param(
        [Parameter(Mandatory)]$Hw,
        [Parameter(Mandatory)]$Profiles
    )
    $best = $null
    foreach ($p in $Profiles) {
        $m = $p.match
        if ($Hw.os.name -notin $m.os) { continue }
        if ($m.gpu_vendor -and $m.gpu_vendor -ne $Hw.gpu_vendor) { continue }
        if ($null -ne $Hw.vram_gb) {
            if ($Hw.vram_gb -lt [double]$m.vram_gb.min) { continue }
            if ($Hw.vram_gb -gt [double]$m.vram_gb.max) { continue }
        }
        if ($null -ne $Hw.ram_gb) {
            if ($Hw.ram_gb -lt [double]$m.ram_gb.min) { continue }
            if ($Hw.ram_gb -gt [double]$m.ram_gb.max) { continue }
        }
        $best = $p
        break
    }
    return $best
}

function Get-LaiPlan {
    <#
    Builds the concrete runtime plan: resolved model manifest + runtime args.
    Never invents values — unresolved planner entries fall back to documented
    safe defaults.
    #>
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)]$Hw,
        [int]$Port = 0,
        [string]$Host_ = ''
    )
    $pl = $Profile.planner
    $port = if ($Port -gt 0) { $Port } else { [int]$pl.port }
    $host_ = if ($Host_) { $Host_ } else { [string]$pl.host }

    # threads: conservative — physical-ish core count, capped
    $cores = [Math]::Max(1, [int]$Hw.cpu_cores)
    $threads = [Math]::Min($cores, 16)

    $args = [ordered]@{
        host            = $host_
        port            = $port
        model_path      = $null     # filled by caller after download
        model_alias     = $Model.model_alias
        ctx             = [int]$pl.ctx
        parallel        = [int]$pl.parallel
        flash_attention = [bool]$pl.flash_attention
        kv_cache_type   = $pl.kv_cache_type
        gpu_layers      = [int]$pl.gpu_layers_override
        threads         = $threads
        batch_size      = [int]$pl.batch_size
        ubatch_size     = [int]$pl.ubatch_size
        mmproj_path     = $null
    }
    return [pscustomobject]@{
        profile      = $Profile
        model        = $Model
        args         = $args
        expected_class = $Profile.expected_class
        notes        = $Profile.notes
    }
}

function Get-LaiDiskRequirement {
    param(
        [Parameter(Mandatory)][long]$ModelBytes,
        [long]$RuntimeBytes = 0,
        [long]$SafetyReserveBytes = 2GB
    )
    $temporaryOverhead = [long]($ModelBytes * 0.02) + 256MB
    return [pscustomobject]@{
        model_bytes     = $ModelBytes
        runtime_bytes   = $RuntimeBytes
        temporary_bytes = $temporaryOverhead
        reserve_bytes   = $SafetyReserveBytes
        required_bytes  = ($ModelBytes + $RuntimeBytes + $temporaryOverhead + $SafetyReserveBytes)
    }
}

function Test-LaiDiskSpace {
    param(
        [Parameter(Mandatory)][long]$RequiredBytes,
        [Parameter(Mandatory)][long]$AvailableBytes
    )
    $shortfall = $RequiredBytes - $AvailableBytes
    return [pscustomobject]@{
        ok        = ($shortfall -le 0)
        required  = $RequiredBytes
        available = $AvailableBytes
        shortfall = if ($shortfall -gt 0) { $shortfall } else { 0 }
    }
}

Export-ModuleMember -Function Select-LaiProfile, Get-LaiPlan,
                              Get-LaiDiskRequirement, Test-LaiDiskSpace
