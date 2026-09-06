# LocalAIDeploy — install root, config and state paths.
# Install root default: %LOCALAPPDATA%\LocalAIDeploy (overridable with
# $env:LOCALAI_HOME). No dependency on any pre-existing user model layout.

function Get-LaiInstallRoot {
    if ($env:LOCALAI_HOME -and -not [string]::IsNullOrWhiteSpace($env:LOCALAI_HOME)) {
        return $env:LOCALAI_HOME
    }
    return (Join-Path $env:LOCALAPPDATA 'LocalAIDeploy')
}

function Get-LaiPaths {
    param([string]$Root = (Get-LaiInstallRoot))
    return @{
        root      = $Root
        runtime   = (Join-Path $Root 'runtime')
        models    = (Join-Path $Root 'models')
        config    = (Join-Path $Root 'config')
        logs      = (Join-Path $Root 'logs')
        state     = (Join-Path $Root 'state')
        downloads = (Join-Path $Root 'downloads')
    }
}

function Initialize-LaiPaths {
    param([string]$Root = (Get-LaiInstallRoot))
    $p = Get-LaiPaths -Root $Root
    foreach ($k in @('runtime', 'models', 'config', 'logs', 'state', 'downloads')) {
        if (-not (Test-Path -LiteralPath $p[$k])) {
            New-Item -ItemType Directory -Path $p[$k] -Force | Out-Null
        }
    }
    return $p
}

function Get-LaiConfigPath {
    param([string]$Root = (Get-LaiInstallRoot))
    return (Join-Path (Get-LaiPaths -Root $Root).config 'config.json')
}

function Get-LaiServerStatePath {
    param([string]$Root = (Get-LaiInstallRoot))
    return (Join-Path (Get-LaiPaths -Root $Root).state 'server.json')
}

function Read-LaiJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Write-LaiJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

Export-ModuleMember -Function Get-LaiInstallRoot, Get-LaiPaths, Initialize-LaiPaths,
                              Get-LaiConfigPath, Get-LaiServerStatePath,
                              Read-LaiJsonFile, Write-LaiJsonFile
