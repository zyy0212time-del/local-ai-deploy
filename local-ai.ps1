<#
.SYNOPSIS
    local-ai — benchmark-driven local AI deployment (v0.1, Windows + NVIDIA + llama.cpp).

.DESCRIPTION
    Detects hardware, selects a curated deployment profile, installs a pinned
    llama.cpp runtime and a pinned GGUF model, then starts an
    OpenAI-compatible local server on localhost.

    Model recommendations come from Reasoning Budget Arena:
    https://github.com/zyy0212time-del/reasoning-budget-arena

.EXAMPLE
    .\local-ai.ps1 install --dry-run
    .\local-ai.ps1 install
    .\local-ai.ps1 status
    .\local-ai.ps1 stop
    .\local-ai.ps1 doctor
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'start', 'stop', 'status', 'doctor', 'models', 'profile', 'update', 'uninstall')]
    [string]$Command = 'status',

    [string]$Model,
    [string]$Category,
    [int]$Port = 0,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$RemoveModels,
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Import-Module (Join-Path $RepoRoot 'src\core\Config.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Log.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Manifests.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Hardware.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Profiles.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Download.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Process.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\runtime\Runtime.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\runtime\LlamaCpp.psm1') -Force
Register-LaiRuntime -Id 'llama-cpp' -ModuleName 'LlamaCpp' -Description 'llama.cpp llama-server (v0.1 default)'

if ($Root) { $env:LOCALAI_HOME = $Root }
$Paths = Initialize-LaiPaths
Initialize-LaiLog -LogDir $Paths.logs

function Get-LaiPlanForInstall {
    param([switch]$DryRunOnly)
    $hw = Get-LaiHardware
    $support = Test-LaiHardwareSupported -Hw $hw
    if (-not $support.supported) {
        Write-LaiError ("unsupported machine: " + ($support.reasons -join '; '))
        return $null
    }
    $profiles = Get-LaiProfiles -RepoRoot $RepoRoot
    $profile = Select-LaiProfile -Hw $hw -Profiles $profiles
    if (-not $profile) {
        Write-LaiError "no profile matches this hardware (v0.1 targets 8-16 GB NVIDIA + 24-64 GB RAM)"
        return $null
    }
    $modelId = if ($Model) { $Model } else { $profile.recommended_model }
    if ($Category) {
        $byCat = Get-LaiModelManifests -RepoRoot $RepoRoot | Where-Object { $_.category -eq $Category } | Select-Object -First 1
        if (-not $byCat) { Write-LaiError "no ready model in category '$Category'"; return $null }
        $modelId = $byCat.id
    }
    $model = Get-LaiModelManifest -RepoRoot $RepoRoot -Id $modelId
    if (-not $model) { Write-LaiError "model manifest not found: $modelId"; return $null }
    $problems = Test-LaiModelManifest -Manifest $model
    if ($problems.Count -gt 0) {
        Write-LaiError ("model manifest '$modelId' is NOT READY: " + ($problems -join '; '))
        return $null
    }
    $port = if ($Port -gt 0) { $Port } else { (Select-LaiPort -Preferred ([int]$profile.planner.port)) }
    if (-not $port) { Write-LaiError "no free port available"; return $null }
    $plan = Get-LaiPlan -Profile $profile -Model $model -Hw $hw -Port $port
    return [pscustomobject]@{ hw = $hw; profile = $profile; model = $model; plan = $plan }
}

function Show-LaiEndpoints {
    <#
    Final success output: browser Chat (llama-server built-in Web UI at the
    server root) and the OpenAI-compatible API base (/v1) are deliberately
    distinguished — /v1 is not a web page.
    #>
    param([Parameter(Mandatory)][string]$Host_, [Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Alias)
    Write-Host ""
    Write-Host "Chat in browser:"
    Write-Host ("  http://{0}:{1}/" -f $Host_, $Port)
    Write-Host ""
    Write-Host "OpenAI-compatible API:"
    Write-Host ("  http://{0}:{1}/v1" -f $Host_, $Port)
    Write-Host ""
    Write-Host "Model:"
    Write-Host ("  {0}" -f $Alias)
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  .\local-ai.ps1 status"
    Write-Host "  .\local-ai.ps1 stop"
    Write-Host "  .\local-ai.ps1 doctor"
}

function Show-Plan {
    param([Parameter(Mandatory)]$Ctx)
    $hw = $Ctx.hw
    Write-Host ""
    Write-Host ("  GPU : {0}" -f $hw.gpu_name)
    Write-Host ("  VRAM: {0} GB" -f $hw.vram_gb)
    Write-Host ("  RAM : {0} GB" -f $hw.ram_gb)
    Write-Host ("  CPU : {0} logical cores" -f $hw.cpu_cores)
    Write-Host ""
    Write-Host "Recommended profile:" -ForegroundColor Cyan
    Write-Host ("  {0} ({1})" -f $Ctx.profile.display_name, $Ctx.profile.id)
    Write-Host ""
    Write-Host "Model:" -ForegroundColor Cyan
    Write-Host ("  {0}" -f $Ctx.model.display_name)
    Write-Host ("  {0} @ {1}" -f $Ctx.model.source_repo, $Ctx.model.revision)
    Write-Host ("  {0} ({1} bytes)" -f $Ctx.model.filename, $Ctx.model.size_bytes)
    Write-Host ("  benchmark: Formal C overall {0}/{1}" -f $Ctx.model.benchmark.formal_c.overall, $Ctx.model.benchmark.formal_c.overall_max)
    Write-Host ""
    Write-Host "Runtime:" -ForegroundColor Cyan
    Write-Host "  llama.cpp (pinned b10375)"
    Write-Host ""
    Write-Host "Configuration:" -ForegroundColor Cyan
    foreach ($k in $Ctx.plan.args.Keys) {
        Write-Host ("  {0,-18} {1}" -f $k, $Ctx.plan.args[$k])
    }
    Write-Host ""
    Write-Host ("Expected class: {0}" -f $Ctx.plan.expected_class)
    Write-Host ("API: http://{0}:{1}/v1" -f $Ctx.plan.args.host, $Ctx.plan.args.port)
    Write-Host ("Model alias: {0}" -f $Ctx.plan.args.model_alias)
    Write-Host ""
}

switch ($Command) {
    'install' {
        $ctx = Get-LaiPlanForInstall
        if (-not $ctx) { exit 1 }
        $modelDest = Join-Path $Paths.models $ctx.model.filename
        $ctx.plan.args.model_path = $modelDest
        if ($ctx.model.multimodal -and $ctx.model.mmproj) {
            $ctx.plan.args.mmproj_path = (Join-Path $Paths.models $ctx.model.mmproj.filename)
        }
        Show-Plan -Ctx $ctx
        $runtimeManifest = Get-LaiRuntimeManifest -RepoRoot $RepoRoot
        $variant = LlamaCpp.Select-Variant -RuntimeManifest $runtimeManifest -Hw $ctx.hw
        $req = Get-LaiDiskRequirement -ModelBytes ([long]$ctx.model.size_bytes) -RuntimeBytes ([long]$variant.size_bytes)
        $disk = Test-LaiDiskSpace -RequiredBytes $req.required_bytes -AvailableBytes ([long]$ctx.hw.free_disk_bytes)
        Write-Host ("Disk: required {0} GB / available {1} GB" -f [Math]::Round($req.required_bytes/1GB,2), [Math]::Round($disk.available/1GB,2))
        if (-not $disk.ok) {
            Write-LaiError ("insufficient disk: shortfall {0} GB" -f [Math]::Round($disk.shortfall/1GB,2))
            exit 1
        }
        if ($DryRun) {
            $argv = LlamaCpp.Get-CommandArguments -Plan $ctx.plan
            Write-Host "Planned llama-server command:" -ForegroundColor Cyan
            Write-Host ("  {0} {1}" -f (LlamaCpp.Get-ServerPath -Paths $Paths), ($argv -join ' '))
            Write-Host ""
            Write-Host "DRY RUN — nothing downloaded, launched, or modified." -ForegroundColor Yellow
            exit 0
        }
        if (-not $Yes) {
            $ans = Read-Host "Proceed with download and installation? (y/N)"
            if ($ans -notmatch '^(y|Y)') { Write-Host "Aborted."; exit 0 }
        }

        # 1) runtime
        $runtimeReady = LlamaCpp.Test-Installed -Paths $Paths
        if (-not $runtimeReady) {
            Write-LaiInfo "downloading llama.cpp $($runtimeManifest.version) ($($variant.id))..."
            $zipPath = Join-Path $Paths.downloads $variant.asset
            $rd = Invoke-LaiDownload -Url $variant.url -DestinationPath $zipPath `
                -ExpectedSha256 $variant.sha256 -ExpectedSize ([long]$variant.size_bytes) `
                -DownloadsDir $Paths.downloads -ArtifactId ("runtime-" + $variant.id)
            if (-not $rd.ok) { Write-LaiError ("runtime download failed: {0}" -f $rd.error); exit 1 }
            Write-LaiInfo "extracting runtime..."
            Expand-Archive -LiteralPath $zipPath -DestinationPath $Paths.runtime -Force
        } else {
            Write-LaiInfo "llama.cpp already installed."
        }

        # 2) model
        if (Test-Path -LiteralPath $modelDest) {
            Write-LaiInfo "model already present; verifying SHA256..."
            $h = Get-LaiFileSha256 -Path $modelDest
            if ($h -ne $ctx.model.sha256) { Write-LaiError "existing model SHA mismatch; refusing to use it"; exit 1 }
            Write-LaiInfo "model verified (SHA256 match)"
        } else {
            Write-LaiInfo "downloading model ($([Math]::Round($ctx.model.size_bytes/1GB,2)) GB)..."
            $murl = "https://huggingface.co/{0}/resolve/{1}/{2}" -f $ctx.model.source_repo, $ctx.model.revision, $ctx.model.filename
            $progress = {
                param($written, $total)
                $pct = [Math]::Round(($written / $total) * 100, 1)
                Write-Host ("  {0}% ({1} / {2} MB)" -f $pct, [Math]::Round($written/1MB), [Math]::Round($total/1MB))
            }
            $md = Invoke-LaiDownload -Url $murl -DestinationPath $modelDest `
                -ExpectedSha256 $ctx.model.sha256 -ExpectedSize ([long]$ctx.model.size_bytes) `
                -DownloadsDir $Paths.downloads -ArtifactId ("model-" + $ctx.model.id) -ProgressWriter $progress
            if (-not $md.ok) { Write-LaiError ("model download failed: {0}" -f $md.error); exit 1 }
            Write-LaiInfo "model INSTALLED (size + SHA256 verified)"
        }

        # 2b) multimodal projector — must exist and verify before launch, otherwise
        # the server would start with a dangling --mmproj path
        if ($ctx.model.multimodal -and $ctx.model.mmproj) {
            $mmDest = $ctx.plan.args.mmproj_path
            $mmSha = $ctx.model.mmproj.sha256
            if (Test-Path -LiteralPath $mmDest) {
                if ($mmSha) {
                    $h = Get-LaiFileSha256 -Path $mmDest
                    if ($h -ne $mmSha) { Write-LaiError "existing mmproj SHA mismatch; refusing to use it"; exit 1 }
                    Write-LaiInfo "mmproj verified (SHA256 match)"
                }
            } elseif ($mmSha) {
                Write-LaiInfo "downloading mmproj ($([Math]::Round($ctx.model.mmproj.size_bytes/1MB)) MB)..."
                $mmUrl = "https://huggingface.co/{0}/resolve/{1}/{2}" -f $ctx.model.source_repo, $ctx.model.revision, $ctx.model.mmproj.filename
                $mmd = Invoke-LaiDownload -Url $mmUrl -DestinationPath $mmDest `
                    -ExpectedSha256 $mmSha -ExpectedSize ([long]$ctx.model.mmproj.size_bytes) `
                    -DownloadsDir $Paths.downloads -ArtifactId ("mmproj-" + $ctx.model.id)
                if (-not $mmd.ok) { Write-LaiError ("mmproj download failed: {0}" -f $mmd.error); exit 1 }
                Write-LaiInfo "mmproj INSTALLED (size + SHA256 verified)"
            } else {
                Write-LaiWarn "mmproj not present and not verifiable in manifest; proceeding text-only (no --mmproj)"
                $ctx.plan.args.mmproj_path = $null
            }
        }

        # 3) config
        $cfg = @{
            version      = '0.1.0'
            profile      = $ctx.profile.id
            model        = $ctx.model.id
            runtime      = $runtimeManifest.id
            runtime_ver  = $runtimeManifest.version
            runtime_variant = $variant.id
            host         = $ctx.plan.args.host
            port         = $ctx.plan.args.port
            alias        = $ctx.plan.args.model_alias
            model_path   = $modelDest
        }
        Write-LaiJsonFile -Path (Get-LaiConfigPath -Root $Paths.root) -Value $cfg

        # 4) start + health
        Write-LaiInfo "starting llama-server..."
        $proc = LlamaCpp.Start-Server -Plan $ctx.plan -Paths $Paths
        Save-LaiServerState -State @{
            pid = $proc.Id; exe = (LlamaCpp.Get-ServerPath -Paths $Paths)
            model = $ctx.model.id; port = $ctx.plan.args.port
            started = (Get-Date).ToString('o'); root = $Paths.root
        } -Root $Paths.root
        $health = LlamaCpp.Invoke-HealthCheck -Plan $ctx.plan -Paths $Paths
        foreach ($c in $health.checks) {
            $mark = if ($c.ok) { 'PASS' } else { 'FAIL' }
            Write-Host ("  {0,-24} {1}" -f $c.name, $mark)
        }
        if (-not $health.ok) {
            Write-LaiError "health check failed; server stopped for safety"
            Stop-LaiServerProcess -Root $Paths.root | Out-Null
            Write-Host "See logs: $($Paths.logs)"
            exit 1
        }
        Write-Host ""
        Write-Host ""
        Write-Host "Local AI is running" -ForegroundColor Green
        Show-LaiEndpoints -Host_ $ctx.plan.args.host -Port $ctx.plan.args.port -Alias $ctx.plan.args.model_alias
        exit 0
    }

    'start' {
        $cfg = Read-LaiJsonFile -Path (Get-LaiConfigPath -Root $Paths.root)
        if (-not $cfg) { Write-LaiError "not installed — run: .\local-ai.ps1 install"; exit 1 }
        $existing = Get-LaiServerState -Root $Paths.root
        if ($existing -and (Test-LaiOwnedProcess -State $existing -Root $Paths.root)) {
            Write-Host "already running (pid $($existing.pid))"; exit 0
        }
        $m = Get-LaiModelManifest -RepoRoot $RepoRoot -Id $cfg.model
        $prof = Get-LaiProfiles -RepoRoot $RepoRoot | Where-Object { $_.id -eq $cfg.profile } | Select-Object -First 1
        $hw = Get-LaiHardware
        $plan = Get-LaiPlan -Profile $prof -Model $m -Hw $hw -Port ([int]$cfg.port)
        $plan.args.model_path = $cfg.model_path
        if ($m.multimodal -and $m.mmproj) { $plan.args.mmproj_path = (Join-Path $Paths.models $m.mmproj.filename) }
        $proc = LlamaCpp.Start-Server -Plan $plan -Paths $Paths
        Save-LaiServerState -State @{
            pid = $proc.Id; exe = (LlamaCpp.Get-ServerPath -Paths $Paths)
            model = $m.id; port = $plan.args.port
            started = (Get-Date).ToString('o'); root = $Paths.root
        } -Root $Paths.root
        $health = LlamaCpp.Invoke-HealthCheck -Plan $plan -Paths $Paths
        foreach ($c in $health.checks) { Write-Host ("  {0,-24} {1}" -f $c.name, $(if ($c.ok) { 'PASS' } else { 'FAIL' })) }
        if (-not $health.ok) { Stop-LaiServerProcess -Root $Paths.root | Out-Null; exit 1 }
        Write-Host "Local AI is running"
        Show-LaiEndpoints -Host_ $plan.args.host -Port $plan.args.port -Alias $plan.args.model_alias
        exit 0
    }

    'stop' {
        $r = Stop-LaiServerProcess -Root $Paths.root
        if ($r.ok) { Write-Host $r.message; exit 0 } else { Write-LaiError $r.message; exit 1 }
    }

    'status' {
        $cfg = Read-LaiJsonFile -Path (Get-LaiConfigPath -Root $Paths.root)
        $state = Get-LaiServerState -Root $Paths.root
        if (-not $cfg) { Write-Host "not installed"; exit 0 }
        Write-Host ("profile : {0}" -f $cfg.profile)
        Write-Host ("model   : {0}" -f $cfg.model)
        Write-Host ("runtime : {0} {1}" -f $cfg.runtime, $cfg.runtime_ver)
        if ($state -and (Test-LaiOwnedProcess -State $state -Root $Paths.root)) {
            Write-Host ("status  : RUNNING (pid {0}, port {1})" -f $state.pid, $state.port) -ForegroundColor Green
            Write-Host ("chat    : http://127.0.0.1:{0}/" -f $state.port)
            Write-Host ("api     : http://127.0.0.1:{0}/v1" -f $state.port)
        } else {
            Write-Host "status  : STOPPED"
        }
        exit 0
    }

    'models' {
        $ms = Get-LaiModelManifests -RepoRoot $RepoRoot
        foreach ($m in $ms) {
            $problems = Test-LaiModelManifest -Manifest $m
            $status = if ($problems.Count -eq 0) { 'READY' } else { 'NOT READY: ' + ($problems -join '; ') }
            Write-Host ("{0,-18} {1,-16} {2}" -f $m.id, $m.category, $status)
            Write-Host ("   {0} @ {1}" -f $m.source_repo, $m.revision)
            Write-Host ("   Formal C overall {0}/{1}  ({2})" -f $m.benchmark.formal_c.overall, $m.benchmark.formal_c.overall_max, $m.benchmark.source)
        }
        exit 0
    }

    'profile' {
        $hw = Get-LaiHardware
        $profiles = Get-LaiProfiles -RepoRoot $RepoRoot
        $p = Select-LaiProfile -Hw $hw -Profiles $profiles
        Write-Host ("GPU  : {0} ({1} GB VRAM)" -f $hw.gpu_name, $hw.vram_gb)
        Write-Host ("RAM  : {0} GB" -f $hw.ram_gb)
        if ($p) {
            Write-Host ("Profile: {0}" -f $p.display_name)
            Write-Host ("Model  : {0}" -f $p.recommended_model)
        } else {
            Write-Host "No matching profile."
        }
        exit 0
    }

    'doctor' {
        & (Join-Path $RepoRoot 'src\commands\doctor.ps1') -RepoRoot $RepoRoot
        exit $LASTEXITCODE
    }

    'update' {
        Write-Host "v0.1: model revisions are pinned and are NOT auto-updated."
        Write-Host "Runtime update is not implemented in v0.1 (see docs/SCOPE.md)."
        exit 0
    }

    'uninstall' {
        # Safe uninstall: stops the owned server, removes runtime + config + state.
        # Downloaded MODELS are only removed with -RemoveModels (multi-GB, may
        # have taken hours to fetch).
        # stop owned server (refuses foreign processes)
        $st = Stop-LaiServerProcess -Root $Paths.root
        if (-not $st.ok) { Write-LaiError $st.message; exit 1 }
        Write-Host $st.message
        foreach ($sub in @('runtime', 'config', 'logs', 'downloads')) {
            $p = Join-Path $Paths.root $sub
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Recurse -Force
                Write-Host ("removed {0}" -f $sub)
            }
        }
        if ($RemoveModels) {
            $mp = Join-Path $Paths.root 'models'
            if (Test-Path -LiteralPath $mp) {
                $gb = [Math]::Round(((Get-ChildItem -LiteralPath $mp -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB, 2)
                Remove-Item -LiteralPath $mp -Recurse -Force
                Write-Host ("removed models ({0} GB)" -f $gb)
            }
            $sp = Join-Path $Paths.root 'state'
            if (Test-Path -LiteralPath $sp) { Remove-Item -LiteralPath $sp -Recurse -Force; Write-Host "removed state" }
            Write-Host "uninstall complete (install root kept, now empty)"
        } else {
            Write-Host "uninstall complete. Downloaded models kept at:"
            Write-Host ("  {0}" -f $Paths.models)
            Write-Host "Remove them explicitly with: .\local-ai.ps1 uninstall -RemoveModels"
        }
        exit 0
    }
}
