# Monotone-HWID-Spoofer
Custom Created Hardware ID Spoofer to Bypass Hardware or IP Bans
<br>
## How To Use
* `git clone https://github.com/sr2echa/Monotone-HWID-Spoofer.git`
* cd `Monotone-HWID-Spoofer`
* open monotone.exe
* give admin privilages
* click 'Unban'
* Enjoy

## Disclaimer
Works for Games like Rust, Fortnite, Apex Legends, etc. that dont use Kernal Based Anti-Cheat [eg. Valorant - Riot Vanguard]

---

## Temporary Mode (fork change)

Original Monotone makes permanent changes — there is no way back to your real
hardware ID. This fork adds a reversible layer: every value is snapshotted
before it is touched, and a single command puts the original identity back.

Spoofed then restored:
* `MachineGuid`  (HKLM\SOFTWARE\Microsoft\Cryptography)
* `HwProfileGuid` (HKLM\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001)
* Volume serial of `C:` (via `Volumeid64.exe`)
* NIC MAC address (per adapter, `NetworkAddress`)
* Computer name (optional, needs a reboot)

### How To Use
* run `TempSpoof.bat` as admin (it self-elevates) and pick from the menu, or call the script direct:
```
powershell -ExecutionPolicy Bypass -File temp-spoof.ps1 -Mode apply
powershell -ExecutionPolicy Bypass -File temp-spoof.ps1 -Mode apply -Seconds 3600
powershell -ExecutionPolicy Bypass -File temp-spoof.ps1 -Mode apply -Hostname
powershell -ExecutionPolicy Bypass -File temp-spoof.ps1 -Mode restore
powershell -ExecutionPolicy Bypass -File temp-spoof.ps1 -Mode status
```

### Guarantees
* Original values stored in `%ProgramData%\Monotone\backup.json` before any write.
* `-Seconds N` arms a timer that restores automatically.
* A logon safety-net task (`MonotoneTempSpoofRestore`) restores on the next
  sign-in if the machine crashes, reboots, or the process is killed while spoofed.
* `-Mode apply` refuses to run if a backup already exists — restore first, so a
  prior original is never overwritten.
* `-NoSafetyNet` skips the logon task if you want a purely manual session.

