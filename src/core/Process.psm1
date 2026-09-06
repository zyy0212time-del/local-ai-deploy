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

function Stop-LaiServerProcess {
    param([string]$Root = (Get-LaiInstallRoot), [int]$TimeoutSeconds = 20)
    $state = Get-LaiServerState -Root $Root
    if (-not $state) {
        return [pscustomobject]@{ ok = $true; message = 'no server state; nothing to stop'; stopped = $false }
    }
    if (-not (Test-LaiOwnedProcess -State $state -Root $Root)) {
        $proc = Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue
        if (-not $proc) {
            # process is gone — nothing to stop; stale state is safe to clear
            Clear-LaiServerState -Root $Root
            return [pscustomobject]@{ ok = $true; stopped = $false; message = "pid $($state.pid) is not running; cleared stale state" }
        }
        return [pscustomobject]@{
            ok      = $false
            stopped = $false
            message = "refusing to stop: pid $($state.pid) is alive but not owned by this install (ownership cannot be proven)"
        }
    }
    $proc = Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue
    if ($proc) {
        try { $proc.CloseMainWindow() | Out-Null } catch { }
        if (-not $proc.WaitForExit(5000)) {
            Stop-Process -Id ([int]$state.pid) -Force
            # wait for actual exit so callers can rely on termination
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
                Start-Sleep -Milliseconds 200
            }
        }
    }
    Clear-LaiServerState -Root $Root
    return [pscustomobject]@{ ok = $true; stopped = $true; message = "stopped pid $($state.pid)" }
}

Export-ModuleMember -Function Get-LaiServerState, Save-LaiServerState,
                              Clear-LaiServerState, Test-LaiOwnedProcess,
                              Test-LaiPortFree, Select-LaiPort,
                              Stop-LaiServerProcess
