<#
  temp-spoof.ps1 - Monotone HWID Spoofer, temporary mode.

  Difference from the original hwid.ps1: nothing is left behind. Every value
  that gets spoofed is snapshotted first and restored by -Mode restore, by the
  -Seconds timer, or by the logon safety-net task if the machine dies while spoofed.

  Values covered:
    MachineGuid        HKLM\SOFTWARE\Microsoft\Cryptography
    HwProfileGuid      HKLM\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001
    Volume serial C:   via Volumeid64.exe
    NIC MAC            NetworkAddress on each adapter class key
    Computer name      optional, -Hostname (needs a reboot to take effect)

  Usage:
    .\temp-spoof.ps1 -Mode apply
    .\temp-spoof.ps1 -Mode apply -Seconds 3600
    .\temp-spoof.ps1 -Mode apply -Hostname
    .\temp-spoof.ps1 -Mode restore
    .\temp-spoof.ps1 -Mode status
#>

[CmdletBinding()]
param(
    [ValidateSet('apply','restore','status')]
    [string]$Mode = 'status',

    [int]$Seconds = 0,

    [switch]$Hostname,

    [switch]$NoSafetyNet
)

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$StateDir   = Join-Path $env:ProgramData 'Monotone'
$BackupFile = Join-Path $StateDir 'backup.json'
$TaskName   = 'MonotoneTempSpoofRestore'

$RegMachine  = 'HKLM:\SOFTWARE\Microsoft\Cryptography'
$RegHwProf   = 'HKLM:\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001'
$AdapterBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$NetCfgPrefix = 'SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator rights required. Re-run from an elevated prompt.'
    }
}

function New-RandomHex([int]$n) {
    $chars = '0123456789abcdef'.ToCharArray()
    -join (1..$n | ForEach-Object { $chars | Get-Random })
}

function New-RandomGuid {
    '{' + (New-RandomHex 8) + '-' + (New-RandomHex 4) + '-' +
          (New-RandomHex 4) + '-' + (New-RandomHex 4) + '-' + (New-RandomHex 12) + '}'
}

function Get-VolumeSerial([string]$drive = 'C:') {
    try {
        (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'").VolumeSerialNumber
    } catch { $null }
}

function Set-VolumeSerial([string]$id, [string]$drive = 'C:') {
    $exe = Join-Path $ScriptDir 'Volumeid64.exe'
    if (-not (Test-Path $exe)) { throw "Volumeid64.exe not found next to the script." }
    & $exe $drive $id | Out-Null
}

function Get-AdapterClassEntries {
    Get-ChildItem $AdapterBase -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' }
}

function Get-AdapterState {
    $list = @()
    foreach ($k in Get-AdapterClassEntries) {
        $props = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
        if (-not $props.NetCfgInstanceId) { continue }
        $had = $null -ne $props.PSObject.Properties['NetworkAddress']
        $list += [pscustomobject]@{
            Key              = $k.PSPath
            Desc             = $props.DriverDesc
            NetCfgInstanceId = $props.NetCfgInstanceId
            HadNetworkAddress = $had
            NetworkAddress   = if ($had) { $props.NetworkAddress } else { $null }
        }
    }
    $list
}

function Restart-AdapterByInstance([string]$instanceId) {
    $guid = $instanceId.Trim('{','}').ToUpper()
    $nic  = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceGuid.Trim('{','}').ToUpper() -eq $guid }
    if ($nic) {
        Restart-NetAdapter -Name $nic.Name -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Invoke-Apply {
    Assert-Admin

    if (Test-Path $BackupFile) {
        throw "A backup already exists at $BackupFile. Run -Mode restore first."
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $state = [ordered]@{
        Created      = (Get-Date).ToString('o')
        MachineGuid  = (Get-ItemProperty $RegMachine -Name MachineGuid).MachineGuid
        HwProfileGuid= (Get-ItemProperty $RegHwProf  -Name HwProfileGuid).HwProfileGuid
        VolumeSerial = Get-VolumeSerial 'C:'
        ComputerName = $env:COMPUTERNAME
        Adapters     = @(Get-AdapterState)
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $BackupFile -Encoding UTF8
    Write-Host "[+] Backup written: $BackupFile"

    if (-not $NoSafetyNet) { Register-SafetyNet }

    Set-ItemProperty -Path $RegMachine -Name MachineGuid   -Value (New-RandomHex 8 + '-' + (New-RandomHex 4) + '-' + (New-RandomHex 4) + '-' + (New-RandomHex 4) + '-' + (New-RandomHex 12))
    Set-ItemProperty -Path $RegHwProf  -Name HwProfileGuid -Value (New-RandomGuid)
    Write-Host '[+] Registry identifiers rotated'

    if ($state.VolumeSerial) {
        $newVol = (New-RandomHex 4).ToUpper() + '-' + (New-RandomHex 4).ToUpper()
        Set-VolumeSerial $newVol 'C:'
        Write-Host "[+] Volume serial $($state.VolumeSerial) -> $newVol"
    }

    $macPool = @(Get-Content (Join-Path $ScriptDir 'mac.txt') -ErrorAction SilentlyContinue |
                 Where-Object { $_ -match '^[0-9a-fA-F]{12}$' })
    $restart = @()
    foreach ($a in $state.Adapters) {
        $mac = if ($macPool.Count) { $macPool | Get-Random } else { '02' + (New-RandomHex 10) }
        New-ItemProperty -Path $a.Key -Name NetworkAddress -Value $mac -PropertyType String -Force | Out-Null
        $restart += $a.NetCfgInstanceId
        Write-Host "[+] NIC '$($a.Desc)' -> $mac"
    }
    foreach ($id in $restart) { Restart-AdapterByInstance $id }

    if ($Hostname) {
        $hostPool = @(Get-Content (Join-Path $ScriptDir 'host.txt') -ErrorAction SilentlyContinue |
                      Where-Object { $_.Trim() -ne '' })
        if ($hostPool.Count) {
            $newName = $hostPool | Get-Random
            if ($newName -ne $env:COMPUTERNAME) {
                Rename-Computer -NewName $newName -Force -ErrorAction SilentlyContinue
                Write-Host "[+] Computer name -> $newName (effective after reboot)"
            }
        }
    }

    Write-Host '[+] Spoof active. Run -Mode restore to revert.'

    if ($Seconds -gt 0) {
        $mins = [math]::Ceiling($Seconds / 60)
        schtasks /create /tn "$TaskName-Timer" /tr "powershell -NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Definition)`" -Mode restore" /sc once /st ((Get-Date).AddSeconds($Seconds).ToString('HH:mm')) /f | Out-Null
        Start-Job -Name MonotoneRevert -ScriptBlock {
            param($s, $p)
            Start-Sleep -Seconds $s
            & powershell -NoProfile -ExecutionPolicy Bypass -File $p -Mode restore
        } -ArgumentList $Seconds, $MyInvocation.MyCommand.Definition | Out-Null
        Write-Host "[+] Auto-revert armed in $Seconds seconds."
    }
}

function Invoke-Restore {
    Assert-Admin

    if (-not (Test-Path $BackupFile)) {
        Write-Host '[!] No backup found. Nothing to restore.'
        Unregister-SafetyNet
        return
    }

    $state = Get-Content $BackupFile -Raw | ConvertFrom-Json

    if ($state.MachineGuid)   { Set-ItemProperty -Path $RegMachine -Name MachineGuid   -Value $state.MachineGuid }
    if ($state.HwProfileGuid) { Set-ItemProperty -Path $RegHwProf  -Name HwProfileGuid -Value $state.HwProfileGuid }
    Write-Host '[+] Registry identifiers restored'

    if ($state.VolumeSerial) {
        Set-VolumeSerial $state.VolumeSerial 'C:'
        Write-Host "[+] Volume serial restored to $($state.VolumeSerial)"
    }

    $restart = @()
    foreach ($a in @($state.Adapters)) {
        if ($a.HadNetworkAddress) {
            New-ItemProperty -Path $a.Key -Name NetworkAddress -Value $a.NetworkAddress -PropertyType String -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $a.Key -Name NetworkAddress -ErrorAction SilentlyContinue
        }
        $restart += $a.NetCfgInstanceId
    }
    foreach ($id in $restart) { Restart-AdapterByInstance $id }
    Write-Host '[+] NIC settings restored'

    if ($state.ComputerName -and $state.ComputerName -ne $env:COMPUTERNAME) {
        Rename-Computer -NewName $state.ComputerName -Force -ErrorAction SilentlyContinue
        Write-Host "[+] Computer name restored to $($state.ComputerName) (effective after reboot)"
    }

    Remove-Item $BackupFile -Force
    Unregister-SafetyNet
    Get-Job -Name MonotoneRevert -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    schtasks /delete /tn "$TaskName-Timer" /f 2>$null | Out-Null
    Write-Host '[+] Spoof reverted. Original identity restored.'
}

function Register-SafetyNet {
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Definition)`" -Mode restore"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Force | Out-Null
    Write-Host '[+] Logon safety-net task registered'
}

function Unregister-SafetyNet {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Invoke-Status {
    if (Test-Path $BackupFile) {
        $s = Get-Content $BackupFile -Raw | ConvertFrom-Json
        Write-Host "SPOOFED (since $($s.Created))"
        Write-Host "  current MachineGuid : $((Get-ItemProperty $RegMachine -Name MachineGuid).MachineGuid)"
        Write-Host "  original MachineGuid: $($s.MachineGuid)"
        Write-Host "  original VolumeSerial: $($s.VolumeSerial)"
    } else {
        Write-Host 'CLEAN - no active backup.'
    }
}

switch ($Mode) {
    'apply'   { Invoke-Apply }
    'restore' { Invoke-Restore }
    'status'  { Invoke-Status }
}
