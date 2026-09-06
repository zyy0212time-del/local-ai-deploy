[CmdletBinding()]
param([int]$Port = 18110)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TinyUrl = 'https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K.gguf'

Import-Module (Join-Path $RepoRoot 'src\core\Config.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Manifests.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Hardware.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Profiles.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Download.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Process.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\runtime\LlamaCpp.psm1') -Force -WarningAction SilentlyContinue

$root = Join-Path $env:TEMP ('lai-webui-' + (Get-Date).ToString('HHmmss'))
$env:LOCALAI_HOME = $root
$paths = Initialize-LaiPaths

try {
    $rtm = Get-LaiRuntimeManifest -RepoRoot $RepoRoot
    $hw = Get-LaiHardware
    $variant = LlamaCpp.Select-Variant -RuntimeManifest $rtm -Hw $hw
    $zip = Join-Path $paths.downloads $variant.asset
    if (-not (Test-Path (Join-Path $paths.runtime 'llama-server.exe'))) {
        Write-Host "downloading runtime..."
        $rd = Invoke-LaiDownload -Url $variant.url -DestinationPath $zip -ExpectedSha256 $variant.sha256 `
            -ExpectedSize ([long]$variant.size_bytes) -DownloadsDir $paths.downloads -ArtifactId 'webui-rt'
        if (-not $rd.ok) { throw "runtime: $($rd.error)" }
        Expand-Archive -LiteralPath $zip -DestinationPath $paths.runtime -Force
    }
    $tinyDest = Join-Path $paths.models 'stories260K.gguf'
    if (-not (Test-Path $tinyDest)) {
        $h = Invoke-WebRequest -Uri $TinyUrl -Method Head -UseBasicParsing -MaximumRedirection 5
        $tr = Invoke-LaiDownload -Url $TinyUrl -DestinationPath $tinyDest -ExpectedSha256 '' `
            -ExpectedSize ([long]$h.Headers['Content-Length']) -DownloadsDir $paths.downloads -ArtifactId 'webui-tiny'
        if (-not $tr.ok) { throw "tiny: $($tr.error)" }
    }
    $profile = Get-LaiProfiles -RepoRoot $RepoRoot | Where-Object { $_.id -eq 'nvidia-8gb-32gb' } | Select-Object -First 1
    $fake = [pscustomobject]@{ id='tiny'; model_alias='tiny'; filename='stories260K.gguf'; size_bytes=1185376; multimodal=$false }
    $plan = Get-LaiPlan -Profile $profile -Model $fake -Hw $hw -Port $Port
    $plan.args.model_path = $tinyDest
    $plan.args.kv_cache_type = 'f16'
    $proc = LlamaCpp.Start-Server -Plan $plan -Paths $paths
    Write-Host "pid $($proc.Id)"
    $deadline = (Get-Date).AddSeconds(120)
    $healthOk = $false
    while ((Get-Date) -lt $deadline) {
        try { if ((Invoke-WebRequest -Uri ("http://127.0.0.1:$Port/health") -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200) { $healthOk = $true; break } } catch { }
        Start-Sleep -Seconds 2
    }
    Write-Host "health: $healthOk"

    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:$Port/") -UseBasicParsing -TimeoutSec 10
    Write-Host "GET-ROOT-STATUS: $($r.StatusCode)"
    Write-Host "GET-ROOT-CTYPE: $($r.Headers['Content-Type'])"
    Write-Host "GET-ROOT-LEN: $($r.Content.Length)"
    Write-Host "GET-ROOT-HTML: $($r.Content -match '<html|<!DOCTYPE|<script')"
    if ($r.Content -match '<title>([^<]*)</title>') { Write-Host "GET-ROOT-TITLE: $($Matches[1])" }

    $h2 = Invoke-WebRequest -Uri ("http://127.0.0.1:$Port/health") -UseBasicParsing -TimeoutSec 5
    Write-Host "API-HEALTH-STATUS: $($h2.StatusCode)"
    $body = @{ model='tiny'; messages=@(@{role='user'; content='say ok'}); max_tokens=8 } | ConvertTo-Json -Depth 5
    $inf = Invoke-RestMethod -Uri ("http://127.0.0.1:$Port/v1/chat/completions") -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 60
    Write-Host "API-INFERENCE-OK: $([bool]$inf.choices[0].message.content)"
} catch {
    Write-Host "EXCEPTION: $($_.Exception.Message)"
} finally {
    Stop-LaiServerProcess -Root $root | Out-Null
    $env:LOCALAI_HOME = $null
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
