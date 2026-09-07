# LocalAIDeploy — llama.cpp runtime implementation (v0.1 only backend).

function LlamaCpp.Test-Installed {
    param([Parameter(Mandatory)]$Paths)
    $exe = Join-Path $Paths.runtime 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    return $true
}

function LlamaCpp.Get-ServerPath {
    param([Parameter(Mandatory)]$Paths)
    return (Join-Path $Paths.runtime 'llama-server.exe')
}

function LlamaCpp.Test-VariantEligible {
    <#
    F-01 fail-closed gate (P0).
    A runtime variant may only be SELECTED or INSTALLED when it is
    integrity-pinned: a non-empty 64-hex sha256 AND sha256_status == VERIFIED.
    Size-only verification is NEVER sufficient for a runtime artifact.
    #>
    param([Parameter(Mandatory)]$Variant)
    if (-not $Variant) { return $false }
    $sha = [string]$Variant.sha256
    $status = [string]$Variant.sha256_status
    if ([string]::IsNullOrWhiteSpace($sha)) { return $false }
    if ($sha -notmatch '^[0-9a-f]{64}$') { return $false }
    if ($status -ne 'VERIFIED') { return $false }
    return $true
}

function LlamaCpp.Assert-VariantEligible {
    param([Parameter(Mandatory)]$Variant)
    if (LlamaCpp.Test-VariantEligible -Variant $Variant) { return $true }
    $id = if ($Variant) { [string]$Variant.id } else { '<null>' }
    throw ("Runtime variant '{0}' is not integrity-pinned and cannot be installed." -f $id)
}

function LlamaCpp.Select-Variant {
    <#
    Chooses the CUDA variant. Modern NVIDIA GPUs (Blackwell / Ada / newer
    Ampere) need the CUDA 13 build; older GPUs fall back to CUDA 12.4.
    Detection is conservative: without a usable signal we pick CUDA 12.4,
    which has the widest driver compatibility.
    Only integrity-pinned (VERIFIED sha256) variants are eligible — F-01.
    #>
    param([Parameter(Mandatory)]$RuntimeManifest, $Hw)
    $prefer13 = $false
    if ($Hw -and $Hw.gpu_name) {
        $n = [string]$Hw.gpu_name
        if ($n -match 'RTX 50|RTX 40|RTX 30|RTX 20') { $prefer13 = ($n -match 'RTX 50|RTX 40') }
    }
    $wanted = if ($prefer13) { 'cuda-13.3' } else { 'cuda-12.4' }
    $variant = $RuntimeManifest.variants | Where-Object { $_.id -eq $wanted -and (LlamaCpp.Test-VariantEligible -Variant $_) } | Select-Object -First 1
    if (-not $variant) {
        # preferred variant not eligible → fall back to ANY eligible variant,
        # never to an unverified one
        $variant = $RuntimeManifest.variants | Where-Object { LlamaCpp.Test-VariantEligible -Variant $_ } | Select-Object -First 1
    }
    if (-not $variant) {
        throw "no integrity-pinned runtime variant is available for this hardware"
    }
    return $variant
}

function LlamaCpp.Install- {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)]$RuntimeManifest,
        $Hw,
        [switch]$DryRun
    )
    $variant = LlamaCpp.Select-Variant -RuntimeManifest $RuntimeManifest -Hw $Hw
    $dest = Join-Path $Paths.runtime $RuntimeManifest.server_binary
    $info = [pscustomobject]@{
        runtime_id = $RuntimeManifest.id
        version    = $RuntimeManifest.version
        variant    = $variant.id
        url        = $variant.url
        asset      = $variant.asset
        size_bytes = $variant.size_bytes
        server_path = $dest
        installed  = (Test-Path -LiteralPath $dest)
        dry_run    = [bool]$DryRun
    }
    if ($DryRun) { return $info }
    if ($info.installed) { return $info }
    # Archive is fetched by the shared downloader (caller) into downloads/, then
    # extracted here. This function only reports the plan and final state.
    return $info
}

function LlamaCpp.Get-CommandArguments {
    <#
    plan.args -> llama-server.exe argument array.
    Only conservative, widely-supported flags are used. No experimental flags.
    #>
    param([Parameter(Mandatory)]$Plan)
    $a = $Plan.args
    $args = @(
        '--model', $a.model_path,
        '--alias', $a.model_alias,
        '--host', $a.host,
        '--port', $a.port,
        '--ctx-size', $a.ctx,
        '--parallel', $a.parallel,
        '--n-gpu-layers', $a.gpu_layers,
        '--threads', $a.threads,
        '--batch-size', $a.batch_size,
        '--ubatch-size', $a.ubatch_size,
        '--cache-type-k', $a.kv_cache_type,
        '--cache-type-v', $a.kv_cache_type
    )
    if ($a.flash_attention) { $args += @('-fa', 'on') }
    if ($a.mmproj_path) { $args += @('--mmproj', $a.mmproj_path) }
    return ($args | ForEach-Object { [string]$_ })
}

function LlamaCpp.Get-HealthUrl {
    param([Parameter(Mandatory)]$Plan)
    return ("http://{0}:{1}/health" -f $Plan.args.host, $Plan.args.port)
}

function LlamaCpp.Get-ModelsUrl {
    param([Parameter(Mandatory)]$Plan)
    return ("http://{0}:{1}/v1/models" -f $Plan.args.host, $Plan.args.port)
}

function LlamaCpp.Start-Server {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Paths)
    $exe = LlamaCpp.Get-ServerPath -Paths $Paths
    if (-not (Test-Path -LiteralPath $exe)) { throw "llama-server not installed at $exe" }
    $argv = LlamaCpp.Get-CommandArguments -Plan $Plan
    $stdout = Join-Path $Paths.logs 'server-stdout.log'
    $stderr = Join-Path $Paths.logs 'server-stderr.log'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.WorkingDirectory = $Paths.runtime
    # NOTE: do NOT redirect stdout/stderr through pipes without a consumer —
    # llama-server's startup banner fills the pipe buffer and deadlocks the
    # child before it starts listening. File redirection (Start-Process) is
    # consumed by the OS and is deadlock-free.
    $quoted = foreach ($v in $argv) { '"' + ([string]$v -replace '"', '\"') + '"' }
    $p = Start-Process -FilePath $exe -ArgumentList $quoted `
        -WorkingDirectory $Paths.runtime `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
        -WindowStyle Hidden -PassThru
    return $p
}

function LlamaCpp.Invoke-HealthCheck {
    <#
    Full health gate: process alive + HTTP reachable + expected alias loaded +
    one minimal inference returns non-empty content.
    #>
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Paths, [int]$TimeoutSec = 180)
    $checks = @()
    $state = Get-LaiServerState -Root $Paths.root
    $alive = if ($state) { (Test-LaiOwnedProcess -State $state -Root $Paths.root) } else { $false }
    $checks += [pscustomobject]@{ name = 'process_alive'; ok = $alive }

    $healthUrl = LlamaCpp.Get-HealthUrl -Plan $Plan
    $reach = $false
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200) { $reach = $true; break }
        } catch { }
        Start-Sleep -Seconds 2
    }
    $checks += [pscustomobject]@{ name = 'http_reachable'; ok = $reach }
    if (-not $reach) {
        return [pscustomobject]@{ ok = $false; checks = $checks; error = 'server did not become reachable' }
    }

    $modelsUrl = LlamaCpp.Get-ModelsUrl -Plan $Plan
    $aliasOk = $false
    try {
        $modelsResp = (Invoke-WebRequest -Uri $modelsUrl -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
        if ($modelsResp -and $modelsResp.data) {
            $ids = @($modelsResp.data | ForEach-Object { $_.id })
            $aliasOk = ($ids -contains $Plan.args.model_alias)
        }
    } catch { }
    $checks += [pscustomobject]@{ name = 'model_alias_loaded'; ok = $aliasOk }

    $inferOk = $false
    try {
        $body = @{
            model    = $Plan.args.model_alias
            messages = @(@{ role = 'user'; content = 'Reply with the single word: ok' })
            max_tokens = 16
        } | ConvertTo-Json -Depth 5
        $resp = Invoke-RestMethod -Uri ("http://{0}:{1}/v1/chat/completions" -f $Plan.args.host, $Plan.args.port) `
            -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120
        $content = $resp.choices[0].message.content
        $inferOk = (-not [string]::IsNullOrWhiteSpace($content))
    } catch { }
    $checks += [pscustomobject]@{ name = 'minimal_inference'; ok = $inferOk }

    $ok = ($checks | Where-Object { -not $_.ok }).Count -eq 0
    return [pscustomobject]@{ ok = $ok; checks = $checks; error = $(if ($ok) { $null } else { 'one or more health checks failed' }) }
}

Export-ModuleMember -Function LlamaCpp.Test-Installed, LlamaCpp.Get-ServerPath,
                              LlamaCpp.Select-Variant, LlamaCpp.Install-,
                              LlamaCpp.Test-VariantEligible, LlamaCpp.Assert-VariantEligible,
                              LlamaCpp.Get-CommandArguments,
                              LlamaCpp.Get-HealthUrl, LlamaCpp.Get-ModelsUrl,
                              LlamaCpp.Start-Server, LlamaCpp.Invoke-HealthCheck
