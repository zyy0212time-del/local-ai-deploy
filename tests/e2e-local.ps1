<#
.SYNOPSIS
    Bounded real end-to-end validation on this machine.

    Uses:
      - an isolated install root under %TEMP%
      - a TINY GGUF (stories260K, ~1 MB) — no large model is downloaded
      - an isolated port in the 18100+ range (never 30003/30005/30006/30007)

    It verifies: runtime download + extraction, config generation, server
    launch, health gate (process + HTTP + alias + inference), stop ownership.

    It does NOT touch: existing model files, Hermes, vv/fimi, Arena, or any
    production service.
#>
[CmdletBinding()]
param([int]$Port = 18100)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TinyUrl = 'https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K.gguf'

Import-Module (Join-Path $RepoRoot 'src\core\Config.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Log.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Manifests.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Profiles.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Hardware.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Download.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Process.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\runtime\Runtime.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\runtime\LlamaCpp.psm1') -Force -WarningAction SilentlyContinue

$root = Join-Path $env:TEMP ('lai-e2e-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
$env:LOCALAI_HOME = $root
$paths = Initialize-LaiPaths
Initialize-LaiLog -LogDir $paths.logs
Write-Host "isolated install root: $root"

$failed = 0
try {
    # 1) runtime
    $rtm = Get-LaiRuntimeManifest -RepoRoot $RepoRoot
    $hw = Get-LaiHardware
    $variant = LlamaCpp.Select-Variant -RuntimeManifest $rtm -Hw $hw
    Write-Host "runtime variant: $($variant.id)"
    $zip = Join-Path $paths.downloads $variant.asset
    Write-Host "downloading llama.cpp $($rtm.version) ..."
    $rd = Invoke-LaiDownload -Url $variant.url -DestinationPath $zip -ExpectedSha256 $null `
        -ExpectedSize ([long]$variant.size_bytes) -DownloadsDir $paths.downloads `
        -ArtifactId ("e2e-runtime-" + $variant.id)
    if (-not $rd.ok) { Write-Host "FAIL runtime download: $($rd.error)" -ForegroundColor Red; $failed++ }
    else {
        Write-Host "  runtime downloaded: $([Math]::Round($rd.bytes/1MB)) MB"
        Expand-Archive -LiteralPath $zip -DestinationPath $paths.runtime -Force
        $exe = LlamaCpp.Get-ServerPath -Paths $paths
        if (Test-Path -LiteralPath $exe) { Write-Host "  llama-server present" -ForegroundColor Green }
        else { Write-Host "FAIL llama-server missing after extract" -ForegroundColor Red; $failed++ }
    }

    # 2) tiny model
    Write-Host "downloading tiny GGUF (1 MB) ..."
    $tinyDest = Join-Path $paths.models 'stories260K.gguf'
    $tinyResp = Invoke-WebRequest -Uri $TinyUrl -Method Head -UseBasicParsing -MaximumRedirection 5
    $tinySize = [long]$tinyResp.Headers['Content-Length']
    $tr = Invoke-LaiDownload -Url $TinyUrl -DestinationPath $tinyDest -ExpectedSha256 $null `
        -ExpectedSize $tinySize -DownloadsDir $paths.downloads -ArtifactId 'e2e-tiny'
    if (-not $tr.ok) { Write-Host "FAIL tiny download: $($tr.error)" -ForegroundColor Red; $failed++ }
    else { Write-Host "  tiny model: $($tr.bytes) bytes, sha=$($tr.sha256.Substring(0,16))..." -ForegroundColor Green }

    # 3) plan + config + launch
    $profile = Get-LaiProfiles -RepoRoot $RepoRoot | Where-Object { $_.id -eq 'nvidia-8gb-32gb' } | Select-Object -First 1
    $fakeModel = [pscustomobject]@{
        id = 'tiny-e2e'; model_alias = 'tiny-e2e'; filename = 'stories260K.gguf'
        size_bytes = $tinySize; multimodal = $false
    }
    $plan = Get-LaiPlan -Profile $profile -Model $fakeModel -Hw $hw -Port $Port
    $plan.args.model_path = $tinyDest
    # the tiny test model has head_dim=8, which is incompatible with quantized
    # KV cache (block size 32); use the unquantized default for this probe only
    $plan.args.kv_cache_type = 'f16'
    $argv = LlamaCpp.Get-CommandArguments -Plan $plan
    Write-Host "launch: $($argv -join ' ')"
    $proc = LlamaCpp.Start-Server -Plan $plan -Paths $paths
    Save-LaiServerState -State @{
        pid = $proc.Id; exe = (LlamaCpp.Get-ServerPath -Paths $paths)
        model = 'tiny-e2e'; port = $Port; started = (Get-Date).ToString('o'); root = $root
    } -Root $root
    Write-Host "  pid $($proc.Id)"

    # 4) health
    $health = LlamaCpp.Invoke-HealthCheck -Plan $plan -Paths $paths -TimeoutSec 90
    foreach ($c in $health.checks) {
        $mark = if ($c.ok) { 'PASS' } else { 'FAIL' }
        $col = if ($c.ok) { 'Green' } else { 'Red' }
        Write-Host ("  {0,-24} {1}" -f $c.name, $mark) -ForegroundColor $col
        if (-not $c.ok) { $failed++ }
    }
    if (-not $health.ok) {
        $errLog = Join-Path $paths.logs 'server-stderr.log'
        $outLog = Join-Path $paths.logs 'server-stdout.log'
        Write-Host "--- server stderr (last 30) ---" -ForegroundColor Yellow
        if (Test-Path -LiteralPath $errLog) { Get-Content -LiteralPath $errLog -Tail 30 | ForEach-Object { Write-Host $_ } } else { Write-Host '(no stderr log)' }
        Write-Host "--- server stdout (last 10) ---" -ForegroundColor Yellow
        if (Test-Path -LiteralPath $outLog) { Get-Content -LiteralPath $outLog -Tail 10 | ForEach-Object { Write-Host $_ } }
        Write-Host "(isolated root preserved: $root)"
        exit 1
    }

    # 5) stop ownership
    $st = Stop-LaiServerProcess -Root $root
    Write-Host "  stop: $($st.message)"
    if (-not $st.ok) { $failed++ }
    $gone = -not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)
    if ($gone) { Write-Host "  process exited: PASS" -ForegroundColor Green } else { Write-Host "  process still alive: FAIL" -ForegroundColor Red; $failed++ }
} catch {
    Write-Host ("EXCEPTION: " + $_.Exception.Message) -ForegroundColor Red
    $failed++
    $env:LOCALAI_HOME = $null
    $errLog = Join-Path $root 'logs\server-stderr.log'
    if (Test-Path -LiteralPath $errLog) {
        Write-Host "--- server stderr (last 25 lines) ---" -ForegroundColor Yellow
        Get-Content -LiteralPath $errLog -Tail 25 | ForEach-Object { Write-Host $_ }
    }
    Write-Host "(isolated root preserved for diagnosis: $root)"
    exit 1
} finally {
    $env:LOCALAI_HOME = $null
}

Write-Host ""
if ($failed -gt 0) { Write-Host "E2E RESULT: FAIL ($failed)" -ForegroundColor Red; exit 1 }
Write-Host "E2E RESULT: PASS" -ForegroundColor Green
exit 0
