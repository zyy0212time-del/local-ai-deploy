<#
.SYNOPSIS
    local-ai doctor — non-destructive diagnostics with PASS / WARN / FAIL.
#>
param([string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)))

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $RepoRoot 'src\core\Config.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Manifests.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Hardware.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Profiles.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Download.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Process.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\runtime\LlamaCpp.psm1') -Force

$Paths = Initialize-LaiPaths
$results = New-Object System.Collections.ArrayList

function Add-Check {
    param([string]$Name, [ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status, [string]$Detail = '')
    $null = $results.Add([pscustomobject]@{ name = $Name; status = $Status; detail = $Detail })
}

# --- hardware -------------------------------------------------------------
$hw = Get-LaiHardware
$sup = Test-LaiHardwareSupported -Hw $hw
Add-Check -Name 'gpu_detection' -Status $(if ($hw.gpu_vendor -eq 'NVIDIA') { 'PASS' } else { 'FAIL' }) -Detail ("{0} ({1} GB VRAM)" -f $hw.gpu_name, $hw.vram_gb)
Add-Check -Name 'ram' -Status $(if ($hw.ram_gb -ge 24) { 'PASS' } elseif ($hw.ram_gb -ge 16) { 'WARN' } else { 'FAIL' }) -Detail ("{0} GB" -f $hw.ram_gb)
Add-Check -Name 'os_support' -Status $(if ($hw.os.supported) { 'PASS' } else { 'FAIL' }) -Detail $hw.os.caption
Add-Check -Name 'hardware_range' -Status $(if ($sup.supported) { 'PASS' } else { 'FAIL' }) -Detail ($sup.reasons -join '; ')

$free = if ($hw.free_disk_bytes) { [Math]::Round($hw.free_disk_bytes / 1GB, 1) } else { 0 }
Add-Check -Name 'disk_space' -Status $(if ($free -ge 30) { 'PASS' } elseif ($free -ge 10) { 'WARN' } else { 'FAIL' }) -Detail ("{0} GB free" -f $free)

# --- runtime --------------------------------------------------------------
$runtimeOk = LlamaCpp.Test-Installed -Paths $Paths
Add-Check -Name 'runtime_present' -Status $(if ($runtimeOk) { 'PASS' } else { 'FAIL' }) -Detail "llama.cpp b10375"

# --- config ---------------------------------------------------------------
$cfg = Read-LaiJsonFile -Path (Get-LaiConfigPath -Root $Paths.root)
Add-Check -Name 'config_valid' -Status $(if ($cfg) { 'PASS' } else { 'WARN' }) -Detail $(if ($cfg) { "model=$($cfg.model) profile=$($cfg.profile)" } else { 'not installed yet' })

# --- model ----------------------------------------------------------------
if ($cfg) {
    $m = Get-LaiModelManifest -RepoRoot $RepoRoot -Id $cfg.model
    if (-not $m) {
        Add-Check -Name 'model_manifest' -Status 'FAIL' -Detail "manifest missing for $($cfg.model)"
    } else {
        $problems = Test-LaiModelManifest -Manifest $m
        Add-Check -Name 'model_manifest' -Status $(if ($problems.Count -eq 0) { 'PASS' } else { 'FAIL' }) -Detail ($problems -join '; ')
        $p = $cfg.model_path
        if (-not (Test-Path -LiteralPath $p)) {
            Add-Check -Name 'model_present' -Status 'FAIL' -Detail $p
            Add-Check -Name 'model_sha256' -Status 'FAIL' -Detail 'model file missing'
        } else {
            $size = (Get-Item -LiteralPath $p).Length
            $sizeOk = ($size -eq [long]$m.size_bytes)
            Add-Check -Name 'model_present' -Status $(if ($sizeOk) { 'PASS' } else { 'FAIL' }) -Detail ("size {0} vs expected {1}" -f $size, $m.size_bytes)
            if ($sizeOk) {
                $h = Get-LaiFileSha256 -Path $p
                Add-Check -Name 'model_sha256' -Status $(if ($h -eq $m.sha256) { 'PASS' } else { 'FAIL' }) -Detail $h
            } else {
                Add-Check -Name 'model_sha256' -Status 'WARN' -Detail 'skipped (size mismatch)'
            }
        }
    }
}

# --- port / server --------------------------------------------------------
$state = Get-LaiServerState -Root $Paths.root
if ($state) {
    $owned = Test-LaiOwnedProcess -State $state -Root $Paths.root
    Add-Check -Name 'server_process_owned' -Status $(if ($owned) { 'PASS' } else { 'WARN' }) -Detail "pid $($state.pid)"
    $portBusy = -not (Test-LaiPortFree -Port ([int]$state.port) -Host '127.0.0.1')
    Add-Check -Name 'port_status' -Status $(if ($owned -and $portBusy) { 'PASS' } else { 'WARN' }) -Detail "port $($state.port) $(if ($portBusy) { 'in use' } else { 'free' })"
    if ($owned -and $cfg) {
        try {
            $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/health" -f $state.port) -UseBasicParsing -TimeoutSec 5
            Add-Check -Name 'server_health' -Status 'PASS' -Detail ("HTTP {0}" -f $r.StatusCode)
        } catch {
            Add-Check -Name 'server_health' -Status 'WARN' -Detail 'health endpoint not responding'
        }
    } else {
        Add-Check -Name 'server_health' -Status 'WARN' -Detail 'server not running'
    }
} else {
    Add-Check -Name 'server_process_owned' -Status 'WARN' -Detail 'no server state'
    Add-Check -Name 'server_health' -Status 'WARN' -Detail 'server not running'
}

# --- manifest versions ----------------------------------------------------
$ms = Get-LaiModelManifests -RepoRoot $RepoRoot
Add-Check -Name 'manifests_loaded' -Status $(if ($ms.Count -gt 0) { 'PASS' } else { 'FAIL' }) -Detail ("{0} manifests" -f $ms.Count)
$profiles = Get-LaiProfiles -RepoRoot $RepoRoot
Add-Check -Name 'profiles_loaded' -Status $(if ($profiles.Count -gt 0) { 'PASS' } else { 'FAIL' }) -Detail ("{0} profiles" -f $profiles.Count)

# --- output ---------------------------------------------------------------
Write-Host ""
Write-Host "local-ai doctor" -ForegroundColor Cyan
Write-Host ("install root: {0}" -f $Paths.root)
Write-Host ""
foreach ($r in $results) {
    $color = switch ($r.status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } }
    Write-Host ("  {0,-24} {1}" -f $r.name, $r.status) -NoNewline -ForegroundColor $color
    if ($r.detail) { Write-Host ("  {0}" -f $r.detail) } else { Write-Host "" }
}
$fail = @($results | Where-Object { $_.status -eq 'FAIL' }).Count
$warn = @($results | Where-Object { $_.status -eq 'WARN' }).Count
Write-Host ""
Write-Host ("summary: FAIL={0} WARN={1} PASS={2}" -f $fail, $warn, (@($results | Where-Object { $_.status -eq 'PASS' }).Count))
Write-Host "doctor makes no changes."
exit $(if ($fail -gt 0) { 1 } else { 0 })
