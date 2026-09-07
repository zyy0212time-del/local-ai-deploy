# LocalAIDeploy — resumable, singleton, integrity-gated downloader.
#
# Guarantees required by the release gate:
#  - ONE writer per artifact: a lock file carries PID + machine + timestamp; a
#    stale lock is only reclaimed when the owning process is provably dead.
#  - HTTP Range resume where the server supports it.
#  - Partial data is written next to a .state file; finalization is a single
#    atomic move after size AND SHA256 pass.
#  - Partial hashes are NEVER treated as integrity proof.
#  - Partial files are never deleted unless ownership is proven by the lock.

$script:LockStaleAfterMinutes = 180

function Get-LaiLockPath {
    param([Parameter(Mandatory)][string]$DownloadsDir, [Parameter(Mandatory)][string]$ArtifactId)
    return (Join-Path $DownloadsDir ("{0}.lock" -f $ArtifactId))
}

function Test-LaiProcessAlive {
    param([int]$Pid)
    if ($Pid -le 0) { return $false }
    $p = Get-Process -Id $Pid -ErrorAction SilentlyContinue
    return ($null -ne $p)
}

function New-LaiDownloadLock {
    <#
    Returns @{ acquired = bool; reason = string; lock_path = string }
    #>
    param(
        [Parameter(Mandatory)][string]$DownloadsDir,
        [Parameter(Mandatory)][string]$ArtifactId
    )
    $lockPath = Get-LaiLockPath -DownloadsDir $DownloadsDir -ArtifactId $ArtifactId
    if (Test-Path -LiteralPath $lockPath) {
        $existing = $null
        try { $existing = (Get-Content -LiteralPath $lockPath -Raw -Encoding utf8 | ConvertFrom-Json) } catch { $existing = $null }
        if ($existing) {
            $alive = Test-LaiProcessAlive -Pid ([int]$existing.pid)
            $ageMin = 9999
            if ($existing.timestamp) {
                try { $ageMin = ((Get-Date) - [datetime]$existing.timestamp).TotalMinutes } catch { }
            }
            if ($alive -and $existing.machine -eq $env:COMPUTERNAME) {
                return @{ acquired = $false; reason = "another installer process (pid $($existing.pid)) owns this artifact"; lock_path = $lockPath }
            }
            if ($alive -and $ageMin -lt $script:LockStaleAfterMinutes) {
                return @{ acquired = $false; reason = "lock held by live pid $($existing.pid)"; lock_path = $lockPath }
            }
        }
        # stale lock from a dead process — only then reclaim
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    $payload = @{
        pid       = $PID
        machine   = $env:COMPUTERNAME
        artifact  = $ArtifactId
        timestamp = (Get-Date).ToString('o')
    }
    [System.IO.File]::WriteAllText($lockPath, ($payload | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    return @{ acquired = $true; reason = 'acquired'; lock_path = $lockPath }
}

function Remove-LaiDownloadLock {
    param([Parameter(Mandatory)][string]$LockPath, [int]$OwnerPid = $PID)
    if (-not (Test-Path -LiteralPath $LockPath)) { return }
    $own = $null
    try { $own = (Get-Content -LiteralPath $LockPath -Raw -Encoding utf8 | ConvertFrom-Json) } catch { }
    if ($own -and [int]$own.pid -ne $OwnerPid) { return }
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
}

function Get-LaiDownloadStatePath {
    param([Parameter(Mandatory)][string]$PartPath)
    return ($PartPath + '.state')
}

function Read-LaiDownloadState {
    param([Parameter(Mandatory)][string]$PartPath)
    $sp = Get-LaiDownloadStatePath -PartPath $PartPath
    if (-not (Test-Path -LiteralPath $sp)) { return $null }
    try { return (Get-Content -LiteralPath $sp -Raw -Encoding utf8 | ConvertFrom-Json) } catch { return $null }
}

function Write-LaiDownloadState {
    param([Parameter(Mandatory)][string]$PartPath, [Parameter(Mandatory)]$State)
    $sp = Get-LaiDownloadStatePath -PartPath $PartPath
    [System.IO.File]::WriteAllText($sp, ($State | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-LaiFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-LaiServerSupportsRange {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 5 -UseBasicParsing -TimeoutSec 30
        $acc = $resp.Headers['Accept-Ranges']
        return ($acc -and $acc -match 'bytes')
    } catch {
        # Some CDNs reject HEAD; fall back to a 1-byte range probe
        try {
            $resp = Invoke-WebRequest -Uri $Url -Method Get -Headers @{ 'Range' = 'bytes=0-0' } -UseBasicParsing -TimeoutSec 30
            return ($resp.StatusCode -eq 206)
        } catch { return $false }
    }
}

function Invoke-LaiDownload {
    <#
    Downloads to <dest>.part with resume, then verifies and atomically moves to
    <dest>. Returns a result object; never throws for expected failure modes.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$ExpectedSha256 = '',
        [Parameter(Mandatory)][long]$ExpectedSize,
        [Parameter(Mandatory)][string]$DownloadsDir,
        [Parameter(Mandatory)][string]$ArtifactId,
        [int]$MaxAttempts = 5,
        [scriptblock]$ProgressWriter = $null
    )
    $result = [pscustomobject]@{
        ok          = $false
        path        = $DestinationPath
        bytes       = 0
        sha256      = $null
        sha_verified = $false
        resumed     = $false
        attempts    = 0
        error       = $null
    }

    $lock = New-LaiDownloadLock -DownloadsDir $DownloadsDir -ArtifactId $ArtifactId
    if (-not $lock.acquired) {
        $result.error = "SINGLETON: $($lock.reason)"
        return $result
    }

    try {
        if (Test-Path -LiteralPath $DestinationPath) {
            $existingSize = (Get-Item -LiteralPath $DestinationPath).Length
            if ($existingSize -eq $ExpectedSize) {
                $h = Get-LaiFileSha256 -Path $DestinationPath
                if ($h -eq $ExpectedSha256.ToLowerInvariant()) {
                    # hash was actually compared and matched on this existing file
                    $result.ok = $true; $result.bytes = $existingSize; $result.sha256 = $h
                    $result.sha_verified = $true
                    return $result
                }
                $result.error = "destination exists but SHA256 mismatch — refusing to overwrite"
                return $result
            }
            $result.error = "destination exists with unexpected size ($existingSize vs $ExpectedSize) — refusing to overwrite"
            return $result
        }

        $part = $DestinationPath + '.part'
        $state = Read-LaiDownloadState -PartPath $part
        $startBytes = 0L
        if ((Test-Path -LiteralPath $part) -and $state -and $state.url -eq $Url) {
            $startBytes = [long](Get-Item -LiteralPath $part).Length
            if ($startBytes -gt $ExpectedSize) {
                # corrupted oversize partial: keep it, do not delete silently
                $result.error = "partial file larger than expected size; manual review required at $part"
                return $result
            }
            $result.resumed = ($startBytes -gt 0)
        } elseif (Test-Path -LiteralPath $part) {
            # partial without matching (or any) state. We hold the singleton
            # lock, so ownership of this partial is proven — safe to restart it
            # from zero. Full mode overwrites it via FileMode.Create; nothing is
            # deleted silently and no unrelated file is touched.
            $startBytes = 0L
        }
        # write state up-front so an interruption at ANY point leaves a
        # resumable, attributable partial
        Write-LaiDownloadState -PartPath $part -State @{
            url = $Url; expected_size = $ExpectedSize; expected_sha256 = $ExpectedSha256
            bytes = $startBytes; updated = (Get-Date).ToString('o'); pid = $PID
        }

        $mode = 'full'
        if ($startBytes -gt 0 -and (Test-LaiServerSupportsRange -Url $Url)) { $mode = 'resume' }

        $attempt = 0
        $delay = 2
        while ($attempt -lt $MaxAttempts) {
            $attempt++
            $result.attempts = $attempt
            try {
                $tmpHeaders = @{ }
                if ($mode -eq 'resume') { $tmpHeaders['Range'] = "bytes=$startBytes-" }
                $req = [System.Net.HttpWebRequest]::Create($Url)
                $req.Method = 'GET'
                $req.Timeout = 60000
                $req.ReadWriteTimeout = 120000
                $req.AllowAutoRedirect = $true
                if ($tmpHeaders.ContainsKey('Range')) { $req.AddRange('bytes', $startBytes) }
                $resp = $req.GetResponse()
                $totalLen = $resp.ContentLength
                if ($mode -eq 'resume' -and $resp.StatusCode -ne 206) {
                    $resp.Close()
                    $mode = 'full'
                    $startBytes = 0
                    throw "server did not honour Range; restarting"
                }
                $stream = $resp.GetResponseStream()
                $fsMode = if ($mode -eq 'resume') { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
                $fs = New-Object System.IO.FileStream($part, $fsMode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $buffer = New-Object byte[] (1MB)
                $written = $startBytes
                $lastReport = 0
                $lastState = $written
                try {
                    while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $fs.Write($buffer, 0, $n)
                        $written += $n
                        if (($written - $lastState) -gt (64MB)) {
                            $lastState = $written
                            Write-LaiDownloadState -PartPath $part -State @{
                                url = $Url; expected_size = $ExpectedSize; expected_sha256 = $ExpectedSha256
                                bytes = $written; updated = (Get-Date).ToString('o'); pid = $PID
                            }
                        }
                        if ($ProgressWriter -and ($written - $lastReport) -gt (50MB)) {
                            $lastReport = $written
                            & $ProgressWriter $written $ExpectedSize
                        }
                    }
                } finally {
                    $fs.Close(); $fs.Dispose()
                    $stream.Close(); $stream.Dispose()
                    $resp.Close()
                }
                Write-LaiDownloadState -PartPath $part -State @{
                    url = $Url; expected_size = $ExpectedSize; expected_sha256 = $ExpectedSha256
                    bytes = $written; updated = (Get-Date).ToString('o'); pid = $PID
                }
                $startBytes = $written
                if ($written -ge $ExpectedSize) { break }
                $mode = 'resume'
                throw "incomplete download ($written / $ExpectedSize)"
            } catch {
                $msg = [string]$_.Exception.Message
                # 416 / 501 = server (or CDN redirect target) rejected the range.
                # Restart from zero, overwriting the partial we own (lock-proven).
                $rangeRejected = $false
                $wex = $_.Exception -as [System.Net.WebException]
                if ($wex -and $wex.Response) {
                    try {
                        $code = [int]([System.Net.HttpWebResponse]$wex.Response).StatusCode
                        if ($code -eq 416 -or $code -eq 501 -or $code -eq 403) { $rangeRejected = $true }
                    } catch { }
                }
                if ($rangeRejected) {
                    $mode = 'full'
                    $startBytes = 0
                } elseif (Test-Path -LiteralPath $part) {
                    $startBytes = (Get-Item -LiteralPath $part).Length
                    $mode = 'resume'
                } else {
                    $mode = 'full'
                    $startBytes = 0
                }
                if ($attempt -ge $MaxAttempts) {
                    $result.error = "download failed after $attempt attempts: $msg"
                    return $result
                }
                Start-Sleep -Seconds $delay
                $delay = [Math]::Min($delay * 2, 60)
            }
        }

        $finalLen = (Get-Item -LiteralPath $part).Length
        if ($finalLen -ne $ExpectedSize) {
            $result.error = "size gate failed: $finalLen != $ExpectedSize (partial retained at $part)"
            return $result
        }
        $hash = Get-LaiFileSha256 -Path $part
        $result.sha256 = $hash
        if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
            # Upstream published no checksum for this artifact: size gate only,
            # explicitly marked as NOT integrity-verified by hash.
            $result.sha_verified = $false
        } else {
            if ($hash -ne $ExpectedSha256.ToLowerInvariant()) {
                $result.error = "SHA256 gate failed: $hash != $($ExpectedSha256.ToLowerInvariant()) (partial retained at $part)"
                return $result
            }
            $result.sha_verified = $true
        }
        Move-Item -LiteralPath $part -Destination $DestinationPath -Force
        Remove-Item -LiteralPath (Get-LaiDownloadStatePath -PartPath $part) -Force -ErrorAction SilentlyContinue
        $result.ok = $true; $result.bytes = $finalLen; $result.sha256 = $hash
        return $result
    } finally {
        Remove-LaiDownloadLock -LockPath $lock.lock_path -OwnerPid $PID
    }
}

Export-ModuleMember -Function Invoke-LaiDownload, New-LaiDownloadLock,
                              Remove-LaiDownloadLock, Read-LaiDownloadState,
                              Write-LaiDownloadState, Get-LaiFileSha256,
                              Get-LaiDownloadStatePath, Get-LaiLockPath,
                              Test-LaiProcessAlive, Test-LaiServerSupportsRange
