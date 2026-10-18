<#
  ui-server.ps1 - local control-panel backend for the Monotone temp-spoof engine.

  Serves ui/index.html and a small JSON API on http://127.0.0.1:8787/.
  It does not spoof anything itself: every action shells out to the existing
  temp-spoof.ps1 so there is exactly one implementation of backup/apply/restore.

  Run elevated (SpooferUI.bat does this) so the child engine has the rights it
  needs. Loopback-only; never binds a public interface.
#>

[CmdletBinding()]
param(
    [int]$Port = 8787,
    [int]$IdleMinutes = 45
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$engine = Join-Path $root 'temp-spoof.ps1'
$indexFile = Join-Path $root 'ui\index.html'
$stateDir = Join-Path $env:ProgramData 'Monotone'
$logFile = Join-Path $stateDir 'ui.log'
$backupFile = Join-Path $stateDir 'backup.json'

if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
if (-not (Test-Path $engine)) { throw "Engine not found: $engine" }

# ---------------------------------------------------------------- logging ----
function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '{0}|{1}|{2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# ------------------------------------------------------------ json helpers ---
function Send-Json {
    param($Context, $Object, [int]$Status = 200)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-File {
    param($Context, [string]$Path, [string]$ContentType)
    if (-not (Test-Path $Path)) { $Context.Response.StatusCode = 404; $Context.Response.Close(); return }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

# ------------------------------------------------------------- registry ------
function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Get-CurrentMachineGuid {
    $v = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Cryptography' 'MachineGuid'
    if ($v) { return [string]$v } else { return $null }
}

function Get-CurrentHwProfileGuid {
    $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001' 'HwProfileGuid'
    if ($v) { return [string]$v } else { return $null }
}

function Get-CurrentVolumeSerial {
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        if ($d -and $d.VolumeSerialNumber) { return [string]$d.VolumeSerialNumber }
    } catch {}
    return $null
}

function Get-MacOverrideCount {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    $count = 0
    try {
        Get-ChildItem -Path $base -ErrorAction Stop | ForEach-Object {
            $na = Get-RegValue $_.PSPath 'NetworkAddress'
            if ($na) { $count++ }
        }
    } catch {}
    return $count
}

function Get-Backup {
    if (-not (Test-Path $backupFile)) { return $null }
    try { return (Get-Content -Raw -Path $backupFile | ConvertFrom-Json) } catch { return $null }
}

# --------------------------------------------------------------- status ------
function Get-Status {
    $bk = Get-Backup
    $backupExists = [bool]$bk

    $curGuid = Get-CurrentMachineGuid
    $curHw = Get-CurrentHwProfileGuid
    $curVol = Get-CurrentVolumeSerial
    $curHost = $env:COMPUTERNAME
    $macCount = Get-MacOverrideCount

    $origGuid = $null; $origHw = $null; $origVol = $null; $origHost = $null
    if ($bk) {
        if ($bk.PSObject.Properties.Name -contains 'MachineGuid') { $origGuid = [string]$bk.MachineGuid }
        if ($bk.PSObject.Properties.Name -contains 'HwProfileGuid') { $origHw = [string]$bk.HwProfileGuid }
        if ($bk.PSObject.Properties.Name -contains 'VolumeSerial') { $origVol = [string]$bk.VolumeSerial }
        if ($bk.PSObject.Properties.Name -contains 'ComputerName') { $origHost = [string]$bk.ComputerName }
        elseif ($bk.PSObject.Properties.Name -contains 'Hostname') { $origHost = [string]$bk.Hostname }
    }

    $guidChanged = $backupExists -and $origGuid -and ($origGuid -ne $curGuid)
    $hostChanged = $backupExists -and $origHost -and ($origHost -ne $curHost)
    $volChanged = $backupExists -and $origVol -and ($origVol -ne $curVol)
    $spoofActive = $guidChanged -or $hostChanged -or $volChanged -or ($macCount -gt 0)

    [pscustomobject]@{
        backupExists   = $backupExists
        spoofActive    = [bool]$spoofActive
        admin          = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        machineGuid    = [pscustomobject]@{ current = $curGuid; original = $origGuid }
        hwProfileGuid  = [pscustomobject]@{ current = $curHw; original = $origHw }
        volumeSerial   = [pscustomobject]@{ current = $curVol; original = $origVol }
        hostname       = [pscustomobject]@{ current = $curHost; original = $origHost }
        nicAddressCount = $macCount
        generatedAt    = (Get-Date).ToString('o')
    }
}

# ------------------------------------------------------------------ log ------
function Get-LogLines {
    if (-not (Test-Path $logFile)) { return @() }
    $raw = Get-Content -Path $logFile -Tail 200 -ErrorAction SilentlyContinue
    $out = New-Object System.Collections.ArrayList
    foreach ($line in $raw) {
        $parts = $line -split '\|', 3
        if ($parts.Count -eq 3) {
            [void]$out.Add([pscustomobject]@{ time = $parts[0]; level = $parts[1].ToLowerInvariant(); msg = $parts[2] })
        } elseif ($line.Trim()) {
            [void]$out.Add([pscustomobject]@{ time = ''; level = 'info'; msg = $line })
        }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------- engine -----
function Invoke-Engine {
    param([string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$engine`"") + ($Arguments | ForEach-Object { "`"$_`"" })) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{ exitCode = $proc.ExitCode; stdout = $stdout; stderr = $stderr }
}

# ---------------------------------------------------------------- routing ----
$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Write-Host "Failed to bind $prefix - is another instance running? $_"
    exit 1
}

Write-Log 'info' "Control panel listening on $prefix"
Write-Host ""
Write-Host "  Monotone control panel -> $prefix" -ForegroundColor DarkYellow
Write-Host "  Close this window (or leave idle $IdleMinutes min) to stop." -ForegroundColor DarkGray
Write-Host ""

$lastActivity = Get-Date
$idleLimit = New-TimeSpan -Minutes $IdleMinutes

try {
    while ($listener.IsListening) {
        if (((Get-Date) - $lastActivity) -gt $idleLimit) {
            Write-Log 'info' 'Idle limit reached; shutting down.'
            break
        }

        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        $lastActivity = Get-Date
        $req = $ctx.Request
        $res = $ctx.Response
        $path = $req.Url.AbsolutePath.ToLowerInvariant()
        $method = $req.HttpMethod.ToUpperInvariant()

        try {
            if (($path -eq '/' -or $path -eq '/index.html') -and $method -eq 'GET') {
                Send-File $ctx $indexFile 'text/html; charset=utf-8'
            }
            elseif ($path -eq '/api/status' -and $method -eq 'GET') {
                Send-Json $ctx (Get-Status)
            }
            elseif ($path -eq '/api/log' -and $method -eq 'GET') {
                Send-Json $ctx @{ lines = @(Get-LogLines) }
            }
            elseif ($path -eq '/api/apply' -and $method -eq 'POST') {
                $body = ''
                if ($req.HasEntityBody) { $sr = New-Object IO.StreamReader($req.InputStream); $body = $sr.ReadToEnd(); $sr.Close() }
                $payload = $null
                if ($body.Trim()) { try { $payload = $body | ConvertFrom-Json } catch {} }

                $engineArgs = @('-Mode', 'apply')
                if ($payload -and $payload.seconds -and [int]$payload.seconds -gt 0) { $engineArgs += @('-Seconds', [string][int]$payload.seconds) }
                if ($payload -and $payload.PSObject.Properties.Name -contains 'hostname' -and $payload.hostname) { $engineArgs += '-Hostname' }
                if ($payload -and $payload.PSObject.Properties.Name -contains 'safetyNet' -and (-not $payload.safetyNet)) { $engineArgs += '-NoSafetyNet' }

                Write-Log 'info' ('apply ' + ($engineArgs -join ' '))
                $r = Invoke-Engine $engineArgs
                if ($r.stdout) { $r.stdout.Trim() -split "`n" | ForEach-Object { if ($_.Trim()) { Write-Log 'info' $_.Trim() } } }
                if ($r.stderr) { $r.stderr.Trim() -split "`n" | ForEach-Object { if ($_.Trim()) { Write-Log 'err' $_.Trim() } } }

                if ($r.exitCode -eq 0) {
                    Send-Json $ctx @{ ok = $true; summary = 'Spoof applied and ready for a restore.'; exitCode = 0 }
                } else {
                    Send-Json $ctx @{ ok = $false; error = (($r.stderr -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)); exitCode = $r.exitCode } 500
                }
            }
            elseif ($path -eq '/api/restore' -and $method -eq 'POST') {
                Write-Log 'info' 'restore'
                $r = Invoke-Engine @('-Mode', 'restore')
                if ($r.stdout) { $r.stdout.Trim() -split "`n" | ForEach-Object { if ($_.Trim()) { Write-Log 'info' $_.Trim() } } }
                if ($r.stderr) { $r.stderr.Trim() -split "`n" | ForEach-Object { if ($_.Trim()) { Write-Log 'err' $_.Trim() } } }

                if ($r.exitCode -eq 0) {
                    Send-Json $ctx @{ ok = $true; summary = 'Original identity restored.'; exitCode = 0 }
                } else {
                    Send-Json $ctx @{ ok = $false; error = (($r.stderr -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)); exitCode = $r.exitCode } 500
                }
            }
            else {
                Send-Json $ctx @{ error = 'not found' } 404
            }
        } catch {
            try { Send-Json $ctx @{ error = [string]$_.Exception.Message } 500 } catch {}
            Write-Log 'err' $_.Exception.Message
        } finally {
            try { $res.Close() } catch {}
        }
    }
}
finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-Log 'info' 'Control panel stopped.'
}
