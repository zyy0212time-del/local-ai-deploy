# LocalAIDeploy — server process ownership and port selection.
#
# Ownership rule: stop/status only act on a process when BOTH the PID in our
# state file matches AND the process executable path lives under this install
# root. Anything else is refused — we never kill unrelated llama-server
# instances or unrelated services.

function Get-LaiServerState {
    param([string]$Root = (Get-LaiInstallRoot))
    $p = Get-LaiServerStatePath -Root $Root
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json) } catch { return $null }
}

function Save-LaiServerState {
    param([Parameter(Mandatory)]$State, [string]$Root = (Get-LaiInstallRoot))
    Write-LaiJsonFile -Path (Get-LaiServerStatePath -Root $Root) -Value $State
}

function Clear-LaiServerState {
    param([string]$Root = (Get-LaiInstallRoot))
    $p = Get-LaiServerStatePath -Root $Root
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

function Test-LaiOwnedProcess {
    param([Parameter(Mandatory)]$State, [string]$Root = (Get-LaiInstallRoot))
    if (-not $State -or -not $State.pid) { return $false }
    $proc = Get-Process -Id ([int]$State.pid) -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    $owned = $false
    try {
        $exe = $proc.Path
        if ($exe -and $exe.ToLowerInvariant().StartsWith($Root.ToLowerInvariant())) { $owned = $true }
    } catch { $owned = $false }
    if ($State.exe -and $owned) {
        $owned = ($exe.ToLowerInvariant() -eq ([string]$State.exe).ToLowerInvariant())
    }
    return $owned
}

function Test-LaiPortFree {
    param([Parameter(Mandatory)][int]$Port, [string]$Host = '127.0.0.1')
    $conn = Get-NetTCPConnection -LocalAddress $Host -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return ($null -eq $conn)
}

function Select-LaiPort {
    <#
    Returns the preferred port when free; otherwise the first free port in the
    18100-18150 range. Never kills an occupying process.
    #>
    param([int]$Preferred = 18100, [string]$Host = '127.0.0.1', [int]$Range = 50)
    if (Test-LaiPortFree -Port $Preferred -Host $Host) { return $Preferred }
    for ($i = 1; $i -le $Range; $i++) {
        $candidate = $Preferred + $i
        if (Test-LaiPortFree -Port $candidate -Host $Host) { return $candidate }
    }
    return $null
}

function Get-LaiOwnedServerProcesses {
    <#
    Path-ownership discovery: any running process whose executable lives under
    <root>\runtime\ belongs to this install. This is the fallback when the
    state file is missing or stale — path evidence is still ownership evidence.
    #>
    param([string]$Root = (Get-LaiInstallRoot))
    $runtimeRoot = (Join-Path $Root 'runtime').ToLowerInvariant().TrimEnd('\')
    $out = @()
    foreach ($p in (Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Path -and $p.Path.ToLowerInvariant().StartsWith($runtimeRoot)) { $out += $p }
        } catch { }
    }
    return , $out
}

function Stop-LaiServerProcess {
    param([string]$Root = (Get-LaiInstallRoot), [int]$TimeoutSeconds = 20)
    $targets = @()
    $state = Get-LaiServerState -Root $Root
    if ($state -and (Test-LaiOwnedProcess -State $state -Root $Root)) {
        $targets += (Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue)
    } elseif ($state -and $state.pid) {
        $proc = Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue
        if ($proc) {
            return [pscustomobject]@{
                ok      = $false
                stopped = $false
                message = "refusing to stop: pid $($state.pid) is alive but not owned by this install (ownership cannot be proven)"
            }
        }
        Clear-LaiServerState -Root $Root
    }
    # path-ownership fallback (also covers the state-recorded pid via its path)
    foreach ($p in (Get-LaiOwnedServerProcesses -Root $Root)) {
        if ($targets -notcontains $p) { $targets += $p }
    }
    if ($targets.Count -eq 0) {
        if ($state) { Clear-LaiServerState -Root $Root }
        return [pscustomobject]@{ ok = $true; stopped = $false; message = 'no owned server process running' }
    }
    foreach ($proc in $targets) {
        try { $proc.CloseMainWindow() | Out-Null } catch { }
        if (-not $proc.WaitForExit(5000)) {
            Stop-Process -Id $proc.Id -Force
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
                Start-Sleep -Milliseconds 200
            }
        }
    }
    Clear-LaiServerState -Root $Root
    $ids = ($targets | ForEach-Object { $_.Id }) -join ', '
    return [pscustomobject]@{ ok = $true; stopped = $true; message = "stopped pid(s) $ids" }
}

Export-ModuleMember -Function Get-LaiServerState, Save-LaiServerState,
                              Clear-LaiServerState, Test-LaiOwnedProcess,
                              Test-LaiPortFree, Select-LaiPort,
                              Stop-LaiServerProcess
