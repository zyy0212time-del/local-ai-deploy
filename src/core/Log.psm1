# LocalAIDeploy — logging
# No sensitive data is logged. Paths under the user profile are logged only as
# relative-to-install-root values.

$script:LogDir = $null

function Initialize-LaiLog {
    param([Parameter(Mandatory)][string]$LogDir)
    $script:LogDir = $LogDir
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
}

function Get-LaiLogPath {
    param([string]$Name = 'install')
    if (-not $script:LogDir) { return $null }
    return (Join-Path $script:LogDir ("{0}.log" -f $Name))
}

function Write-LaiLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO',
        [string]$LogName = 'install'
    )
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "{0} [{1}] {2}" -f $ts, $Level, $Message
    $p = Get-LaiLogPath -Name $LogName
    if ($p) {
        try { Add-Content -LiteralPath $p -Value $line -Encoding utf8 } catch { }
    }
    return $line
}

function Write-LaiInfo {
    param([Parameter(Mandatory)][string]$Message, [string]$LogName = 'install')
    Write-LaiLog -Message $Message -Level 'INFO' -LogName $LogName | Out-Null
    Write-Host $Message
}

function Write-LaiWarn {
    param([Parameter(Mandatory)][string]$Message, [string]$LogName = 'install')
    Write-LaiLog -Message $Message -Level 'WARN' -LogName $LogName | Out-Null
    Write-Host ("WARN  " + $Message) -ForegroundColor Yellow
}

function Write-LaiError {
    param([Parameter(Mandatory)][string]$Message, [string]$LogName = 'install')
    Write-LaiLog -Message $Message -Level 'ERROR' -LogName $LogName | Out-Null
    Write-Host ("ERROR " + $Message) -ForegroundColor Red
}

Export-ModuleMember -Function Initialize-LaiLog, Get-LaiLogPath, Write-LaiLog,
                              Write-LaiInfo, Write-LaiWarn, Write-LaiError
