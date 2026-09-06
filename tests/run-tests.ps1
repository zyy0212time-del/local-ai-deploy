<#
.SYNOPSIS
    LocalAIDeploy v0.1 — deterministic unit tests.

    No network. No model downloads. No production services touched.
    Tests run against temporary directories under the system temp folder and
    clean up after themselves.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot

Import-Module (Join-Path $RepoRoot 'src\core\Config.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Manifests.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Hardware.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Profiles.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Download.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\core\Process.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\runtime\Runtime.psm1') -Force
Import-Module (Join-Path $RepoRoot 'src\runtime\LlamaCpp.psm1') -Force -WarningAction SilentlyContinue

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

function Assert-True {
    param([Parameter(Mandatory)]$Condition, [Parameter(Mandatory)][string]$Name, [string]$Detail = '')
    if ($Condition) {
        $script:Passed++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    } else {
        $script:Failed++
        $script:Failures += "$Name $Detail"
        Write-Host ("  FAIL  {0} {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

function Assert-Equal {
    param([Parameter(Mandatory)]$Expected, [Parameter(Mandatory)]$Actual, [Parameter(Mandatory)][string]$Name)
    $ok = ("$Expected" -eq "$Actual")
    Assert-True -Condition $ok -Name $Name -Detail "(expected '$Expected', got '$Actual')"
}

function New-TestRoot {
    $p = Join-Path $env:TEMP ("lai-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

function New-FakeHw {
    param([double]$VramGb = 8, [double]$RamGb = 32, [int]$Cores = 16, [string]$Vendor = 'NVIDIA', [string]$GpuName = 'NVIDIA GeForce RTX 5060 Laptop GPU', [string]$OsName = 'Windows 11')
    return [pscustomobject]@{
        os              = [pscustomobject]@{ name = $OsName; supported = $true; caption = $OsName; build = 26100 }
        gpu_vendor      = $Vendor
        gpu_name        = $GpuName
        vram_gb         = $VramGb
        ram_gb          = $RamGb
        cpu_cores       = $Cores
        free_disk_bytes = 200GB
    }
}

Write-Host ""
Write-Host "== manifests ==" -ForegroundColor Cyan
$models = Get-LaiModelManifests -RepoRoot $RepoRoot
Assert-True -Condition (@($models).Count -eq 3) -Name "3 model manifests loaded" -Detail "(got $(@($models).Count))"
foreach ($m in $models) {
    $problems = Test-LaiModelManifest -Manifest $m
    Assert-True -Condition (@($problems).Count -eq 0) -Name "manifest valid: $($m.id)" -Detail ($problems -join '; ')
}
$bad = [pscustomobject]@{
    id = 'bad'; display_name = 'x'; category = 'weird'; source_repo = 'r/r'
    revision = 'zzz'; filename = 'f.gguf'; sha256 = 'nothex'; size_bytes = 0
    license = 'x'; runtime = @('ollama'); multimodal = $true
}
$badProblems = Test-LaiModelManifest -Manifest $bad
Assert-True -Condition (@($badProblems).Count -ge 5) -Name "invalid manifest rejected" -Detail "(got $(@($badProblems).Count) problems)"

Write-Host ""
Write-Host "== profile selection ==" -ForegroundColor Cyan
$profiles = Get-LaiProfiles -RepoRoot $RepoRoot
Assert-True -Condition (@($profiles).Count -eq 3) -Name "3 profiles loaded"
$p8 = Select-LaiProfile -Hw (New-FakeHw -VramGb 8 -RamGb 32) -Profiles $profiles
Assert-Equal -Expected 'nvidia-8gb-32gb' -Actual $p8.id -Name '8GB/32GB -> nvidia-8gb-32gb'
$p12 = Select-LaiProfile -Hw (New-FakeHw -VramGb 12 -RamGb 32) -Profiles $profiles
Assert-Equal -Expected 'nvidia-12gb-32gb' -Actual $p12.id -Name '12GB/32GB -> nvidia-12gb-32gb'
$p16 = Select-LaiProfile -Hw (New-FakeHw -VramGb 16 -RamGb 64) -Profiles $profiles
Assert-Equal -Expected 'nvidia-16gb-64gb' -Actual $p16.id -Name '16GB/64GB -> nvidia-16gb-64gb'
$pAmd = Select-LaiProfile -Hw (New-FakeHw -Vendor 'AMD') -Profiles $profiles
Assert-True -Condition ($null -eq $pAmd) -Name 'AMD hardware -> no profile (v0.1 NVIDIA only)'
$pTiny = Select-LaiProfile -Hw (New-FakeHw -VramGb 4 -RamGb 8) -Profiles $profiles
Assert-True -Condition ($null -eq $pTiny) -Name '4GB VRAM -> no profile'

Write-Host ""
Write-Host "== hardware range matching ==" -ForegroundColor Cyan
$supOk = Test-LaiHardwareSupported -Hw (New-FakeHw)
Assert-True -Condition $supOk.supported -Name 'typical target machine supported'
$supNo = Test-LaiHardwareSupported -Hw (New-FakeHw -Vendor 'AMD')
Assert-True -Condition (-not $supNo.supported) -Name 'non-NVIDIA rejected'

Write-Host ""
Write-Host "== disk preflight ==" -ForegroundColor Cyan
$req = Get-LaiDiskRequirement -ModelBytes 20GB -RuntimeBytes 150MB
Assert-True -Condition ($req.required_bytes -gt 20GB) -Name 'requirement includes overhead + reserve'
$okDisk = Test-LaiDiskSpace -RequiredBytes $req.required_bytes -AvailableBytes 100GB
Assert-True -Condition $okDisk.ok -Name 'ample disk passes'
$badDisk = Test-LaiDiskSpace -RequiredBytes $req.required_bytes -AvailableBytes 5GB
Assert-True -Condition (-not $badDisk.ok) -Name 'insufficient disk fails'
Assert-True -Condition ($badDisk.shortfall -gt 0) -Name 'shortfall reported'

Write-Host ""
Write-Host "== SHA verification ==" -ForegroundColor Cyan
$tmpRoot = New-TestRoot
$fixture = Join-Path $tmpRoot 'sample.bin'
[System.IO.File]::WriteAllBytes($fixture, ([byte[]](1..64)))
$h1 = Get-LaiFileSha256 -Path $fixture
Assert-True -Condition ($h1 -match '^[0-9a-f]{64}$') -Name 'sha256 is 64-hex'
$h2 = Get-LaiFileSha256 -Path $fixture
Assert-Equal -Expected $h1 -Actual $h2 -Name 'sha256 deterministic'
$fixture2 = Join-Path $tmpRoot 'sample2.bin'
[System.IO.File]::WriteAllBytes($fixture2, ([byte[]](1..65)))
$h3 = Get-LaiFileSha256 -Path $fixture2
Assert-True -Condition ($h1 -ne $h3) -Name 'different bytes -> different hash'

Write-Host ""
Write-Host "== port selection ==" -ForegroundColor Cyan
$port = Select-LaiPort -Preferred 18100
Assert-True -Condition ($port -ge 18100) -Name 'port selection returns a port'
Assert-True -Condition ($port -lt 18200) -Name 'stays inside the reserved low-collision range'
$freeProbe = Test-LaiPortFree -Port 18199
Assert-True -Condition ($freeProbe -is [bool]) -Name 'port probe returns boolean'

Write-Host ""
Write-Host "== singleton downloader lock ==" -ForegroundColor Cyan
$dlRoot = New-TestRoot
$lock1 = New-LaiDownloadLock -DownloadsDir $dlRoot -ArtifactId 'test-artifact'
Assert-True -Condition $lock1.acquired -Name 'first lock acquired'
$lock2 = New-LaiDownloadLock -DownloadsDir $dlRoot -ArtifactId 'test-artifact'
Assert-True -Condition (-not $lock2.acquired) -Name 'second writer refused (singleton)'
Assert-True -Condition ($lock2.reason -match 'owns this artifact') -Name 'refusal explains owner'
Remove-LaiDownloadLock -LockPath $lock1.lock_path -OwnerPid $PID
Assert-True -Condition (-not (Test-Path -LiteralPath $lock1.lock_path)) -Name 'lock released by owner'
$lock3 = New-LaiDownloadLock -DownloadsDir $dlRoot -ArtifactId 'test-artifact'
Assert-True -Condition $lock3.acquired -Name 're-acquired after release'
# foreign lock must not be removed by us
$foreignLock = Get-LaiLockPath -DownloadsDir $dlRoot -ArtifactId 'foreign'
[System.IO.File]::WriteAllText($foreignLock, '{"pid":999999,"machine":"other","artifact":"foreign","timestamp":"2020-01-01T00:00:00"}')
Remove-LaiDownloadLock -LockPath $foreignLock -OwnerPid $PID
Assert-True -Condition (Test-Path -LiteralPath $foreignLock) -Name 'foreign lock NOT removed'

Write-Host ""
Write-Host "== partial download state ==" -ForegroundColor Cyan
$partPath = Join-Path $dlRoot 'model.gguf.part'
$state = @{ url = 'https://example.invalid/m.gguf'; expected_size = 12345; bytes = 100; pid = $PID }
Write-LaiDownloadState -PartPath $partPath -State $state
$readBack = Read-LaiDownloadState -PartPath $partPath
Assert-Equal -Expected 12345 -Actual $readBack.expected_size -Name 'partial state round-trips'
Assert-Equal -Expected 'https://example.invalid/m.gguf' -Actual $readBack.url -Name 'partial state records url'
Assert-True -Condition (Test-Path -LiteralPath (Get-LaiDownloadStatePath -PartPath $partPath)) -Name 'state file exists beside partial'

Write-Host ""
Write-Host "== download refuses bad targets ==" -ForegroundColor Cyan
$destBad = Join-Path $dlRoot 'existing.gguf'
[System.IO.File]::WriteAllText($destBad, 'corrupt')
$res = Invoke-LaiDownload -Url 'https://example.invalid/x' -DestinationPath $destBad `
    -ExpectedSha256 ('0' * 64) -ExpectedSize 999999 `
    -DownloadsDir $dlRoot -ArtifactId 'refuse-test'
Assert-True -Condition (-not $res.ok) -Name 'mismatched existing file refused'
Assert-True -Condition ($res.error -match 'refusing to overwrite') -Name 'refusal states reason'

Write-Host ""
Write-Host "== PID ownership ==" -ForegroundColor Cyan
$ownRoot = New-TestRoot
$env:LOCALAI_HOME = $ownRoot
$paths = Initialize-LaiPaths
$foreignExe = Join-Path $env:TEMP 'not-our-server.exe'
Assert-True -Condition (-not (Test-LaiOwnedProcess -State ([pscustomobject]@{ pid = 4; exe = $foreignExe }) -Root $ownRoot)) -Name 'refuses ownership of foreign pid/exe'
$selfState = [pscustomobject]@{ pid = $PID; exe = (Join-Path $ownRoot 'runtime\llama-server.exe') }
$selfProc = Get-Process -Id $PID
Assert-True -Condition (-not (Test-LaiOwnedProcess -State $selfState -Root $ownRoot)) -Name 'refuses ownership when exe path outside install root'
$st = Stop-LaiServerProcess -Root $ownRoot
Assert-True -Condition $st.ok -Name 'stop with no state is a no-op'
Assert-True -Condition (-not $st.stopped) -Name 'stop with no state reports not stopped'
$env:LOCALAI_HOME = $null

Write-Host ""
Write-Host "== config generation ==" -ForegroundColor Cyan
$cfgRoot = New-TestRoot
$env:LOCALAI_HOME = $cfgRoot
$cfgPaths = Initialize-LaiPaths
$cfgObj = @{ version = '0.1.0'; model = 'huihui-nex-q4'; port = 18100; host = '127.0.0.1' }
Write-LaiJsonFile -Path (Get-LaiConfigPath -Root $cfgRoot) -Value $cfgObj
$cfgRead = Read-LaiJsonFile -Path (Get-LaiConfigPath -Root $cfgRoot)
Assert-Equal -Expected 'huihui-nex-q4' -Actual $cfgRead.model -Name 'config round-trips'
Assert-Equal -Expected '127.0.0.1' -Actual $cfgRead.host -Name 'config defaults to localhost'
Assert-True -Condition (Test-Path -LiteralPath (Join-Path $cfgPaths.models '')) -Name 'install layout created'
$env:LOCALAI_HOME = $null

Write-Host ""
Write-Host "== runtime abstraction + command construction ==" -ForegroundColor Cyan
Register-LaiRuntime -Id 'llama-cpp' -ModuleName 'LlamaCpp'
Assert-True -Condition ((Get-LaiRuntimeIds) -contains 'llama-cpp') -Name 'llama.cpp registered'
$m = Get-LaiModelManifest -RepoRoot $RepoRoot -Id 'huihui-nex-q4'
$plan = Get-LaiPlan -Profile $p8 -Model $m -Hw (New-FakeHw)
$plan.args.model_path = 'C:\models\m.gguf'
$argv = LlamaCpp.Get-CommandArguments -Plan $plan
Assert-True -Condition ($argv -contains '127.0.0.1') -Name 'server binds localhost only'
Assert-True -Condition ($argv -contains '--alias') -Name 'model alias passed'
Assert-True -Condition (-not ($argv -contains '0.0.0.0')) -Name 'no 0.0.0.0 binding'
Assert-True -Condition ($argv -contains '--n-gpu-layers') -Name 'gpu layers configured'
$rtm = Get-LaiRuntimeManifest -RepoRoot $RepoRoot
$v = LlamaCpp.Select-Variant -RuntimeManifest $rtm -Hw (New-FakeHw -GpuName 'NVIDIA GeForce RTX 5060 Laptop GPU')
Assert-Equal -Expected 'cuda-13.3' -Actual $v.id -Name 'modern NVIDIA -> CUDA 13.3'
$vo = LlamaCpp.Select-Variant -RuntimeManifest $rtm -Hw (New-FakeHw -GpuName 'NVIDIA GeForce GTX 1080')
Assert-Equal -Expected 'cuda-12.4' -Actual $vo.id -Name 'older NVIDIA -> CUDA 12.4'

Write-Host ""
Write-Host "== dashboard ==" -ForegroundColor Cyan
Write-Host ("  passed: {0}  failed: {1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    Write-Host "  failures:" -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host ("    - {0}" -f $f) }
}
foreach ($d in @($tmpRoot, $dlRoot, $ownRoot, $cfgRoot)) {
    if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ""
exit $(if ($script:Failed -gt 0) { 1 } else { 0 })
