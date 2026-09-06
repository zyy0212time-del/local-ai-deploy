# LocalAIDeploy — hardware detection (Windows + NVIDIA only in v0.1).
# Values are collected from CIM and are only used for profile matching; nothing
# is uploaded anywhere.

function Get-LaiWindowsVersion {
    $os = Get-CimInstance Win32_OperatingSystem
    $caption = [string]$os.Caption
    $build = [int]$os.BuildNumber
    $name = if ($build -ge 22000) { 'Windows 11' } elseif ($build -ge 10240) { 'Windows 10' } else { 'Windows (unsupported)' }
    return [pscustomobject]@{
        caption  = $caption
        build    = $build
        name     = $name
        arch     = $env:PROCESSOR_ARCHITECTURE
        supported = ($build -ge 10240)
    }
}

function Get-LaiGpu {
    $vcs = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -ne $null })
    $nvidia = @($vcs | Where-Object { $_.Name -match 'NVIDIA' })
    $gpus = foreach ($v in $vcs) {
        $vramBytes = $null
        if ($v.AdapterRAM -and $v.AdapterRAM -gt 0) { $vramBytes = [double]$v.AdapterRAM }
        [pscustomobject]@{
            name       = [string]$v.Name
            vendor     = if ($v.Name -match 'NVIDIA') { 'NVIDIA' } elseif ($v.Name -match 'AMD|Radeon') { 'AMD' } elseif ($v.Name -match 'Intel') { 'Intel' } else { 'Other' }
            driver     = [string]$v.DriverVersion
            vram_bytes = $vramBytes
        }
    }
    return [pscustomobject]@{
        all        = , $gpus
        nvidia     = , $nvidia
        has_nvidia = ($nvidia.Count -gt 0)
    }
}

function Get-LaiVramBytes {
    <#
    AdapterRAM is unreliable on many Windows systems (it can report 4GB or be
    missing entirely). Prefer the NVIDIA SMI probe when available, then fall
    back to AdapterRAM, then to a WMI registry-free estimate of null.
    #>
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        try {
            $out = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) {
                $first = ([string]$out).Split("`n")[0].Trim()
                $mib = [double]$first
                if ($mib -gt 0) { return [long]($mib * 1MB) }
            }
        } catch { }
    }
    $gpus = Get-LaiGpu
    foreach ($g in $gpus.nvidia) {
        $prop = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -eq $g.name } | Select-Object -First 1
        if ($prop -and $prop.AdapterRAM -gt 0) { return [long]$prop.AdapterRAM }
    }
    return $null
}

function Get-LaiHardware {
    $os = Get-LaiWindowsVersion
    $gpu = Get-LaiGpu
    $vram = Get-LaiVramBytes
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ramBytes = [double]$cs.TotalPhysicalMemory
    $sysDrive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        os              = $os
        gpu_vendor      = if ($gpu.has_nvidia) { 'NVIDIA' } else { ($gpu.all | Select-Object -First 1).vendor }
        gpu_name        = if ($gpu.has_nvidia) { ($gpu.nvidia | Select-Object -First 1).name } else { ($gpu.all | Select-Object -First 1).name }
        gpu_driver      = if ($gpu.has_nvidia) { ($gpu.nvidia | Select-Object -First 1).driver } else { $null }
        vram_bytes      = $vram
        vram_gb         = if ($vram) { [Math]::Round($vram / 1GB, 1) } else { $null }
        ram_bytes       = $ramBytes
        ram_gb          = [Math]::Round($ramBytes / 1GB, 1)
        cpu_name        = [string]$cpu.Name
        cpu_cores       = [int]$cpu.NumberOfLogicalProcessors
        free_disk_bytes = if ($sysDrive) { [double]$sysDrive.Free } else { $null }
    }
}

function Test-LaiHardwareSupported {
    param([Parameter(Mandatory)]$Hw)
    $reasons = @()
    if (-not $Hw.os.supported) { $reasons += "OS not supported (v0.1 supports Windows 10/11)" }
    if ($Hw.gpu_vendor -ne 'NVIDIA') { $reasons += "no NVIDIA GPU detected (v0.1 is NVIDIA-only)" }
    if ($Hw.ram_gb -lt 16) { $reasons += "system RAM below the 16 GB practical floor" }
    if (-not $Hw.vram_gb) { $reasons += "VRAM could not be determined" }
    elseif ($Hw.vram_gb -lt 6) { $reasons += "VRAM below 6 GB (v0.1 targets 8-16 GB)" }
    return [pscustomobject]@{
        supported = ($reasons.Count -eq 0)
        reasons   = , $reasons
    }
}

Export-ModuleMember -Function Get-LaiHardware, Get-LaiGpu, Get-LaiWindowsVersion,
                              Get-LaiVramBytes, Test-LaiHardwareSupported
