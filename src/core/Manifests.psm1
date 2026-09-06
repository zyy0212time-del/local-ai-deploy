# LocalAIDeploy — manifest loading and schema validation.
# Manifests are pinned: revision + sha256 + size are mandatory for a model to be
# considered READY. Missing verification data marks a manifest NOT READY and the
# installer refuses to use it.

$script:RequiredModelFields = @(
    'id', 'display_name', 'category', 'source_repo', 'revision', 'filename',
    'sha256', 'size_bytes', 'license', 'runtime'
)

function Get-LaiModelManifests {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $dir = Join-Path $RepoRoot 'models'
    $out = @()
    if (-not (Test-Path -LiteralPath $dir)) { return $out }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File) {
        $m = (Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8) | ConvertFrom-Json
        $m | Add-Member -NotePropertyName '_file' -NotePropertyValue $f.Name -Force
        $out += $m
    }
    return $out
}

function Get-LaiModelManifest {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Id)
    return (Get-LaiModelManifests -RepoRoot $RepoRoot | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

function Test-LaiModelManifest {
    param([Parameter(Mandatory)]$Manifest)
    $problems = @()
    foreach ($f in $script:RequiredModelFields) {
        $p = $Manifest.PSObject.Properties[$f]
        if (-not $p -or $null -eq $p.Value -or ($p.Value -is [string] -and [string]::IsNullOrWhiteSpace($p.Value))) {
            $problems += "missing field: $f"
        }
    }
    if ($Manifest.category -and $Manifest.category -notin @('balanced', 'cyber-uncensored', 'fast')) {
        $problems += "unknown category: $($Manifest.category)"
    }
    if ($Manifest.sha256 -and $Manifest.sha256 -notmatch '^[0-9a-f]{64}$') {
        $problems += "sha256 is not a 64-hex string"
    }
    if ($Manifest.revision -and $Manifest.revision -notmatch '^[0-9a-f]{7,40}$') {
        $problems += "revision is not a hex commit id"
    }
    if ($Manifest.size_bytes -and $Manifest.size_bytes -le 0) {
        $problems += "size_bytes must be positive"
    }
    if ($Manifest.multimodal -and -not $Manifest.mmproj) {
        $problems += "multimodal manifest must declare mmproj"
    }
    if ($Manifest.benchmark -and $Manifest.benchmark.formal_c) {
        $fc = $Manifest.benchmark.formal_c
        if ($null -ne $fc.overall -and $null -ne $fc.overall_max -and $fc.overall -gt $fc.overall_max) {
            $problems += "benchmark overall exceeds max"
        }
    }
    if ($Manifest.runtime -and 'llama.cpp' -notin $Manifest.runtime) {
        $problems += "v0.1 requires llama.cpp in runtime list"
    }
    return , $problems
}

function Get-LaiProfiles {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $dir = Join-Path $RepoRoot 'profiles'
    $out = @()
    if (-not (Test-Path -LiteralPath $dir)) { return $out }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File) {
        $out += ((Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8) | ConvertFrom-Json)
    }
    return $out
}

function Get-LaiRuntimeManifest {
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$Id = 'llama-cpp')
    $p = Join-Path $RepoRoot 'runtimes'
    $f = Join-Path $p 'llama-cpp-b10375.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    return ((Get-Content -LiteralPath $f -Raw -Encoding utf8) | ConvertFrom-Json)
}

Export-ModuleMember -Function Get-LaiModelManifests, Get-LaiModelManifest,
                              Test-LaiModelManifest, Get-LaiProfiles,
                              Get-LaiRuntimeManifest
