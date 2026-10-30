# Shinoque launch diagnostics. Paste into PowerShell (not as admin).
# Writes Desktop\shinoque-diagnostics.txt. Reads only Shinoque's own files,
# logs only error lines, and stops nothing but Shinoque itself.
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'shinoque-diagnostics.txt'
& {
  "== $(Get-Date -Format s)  Windows build $([Environment]::OSVersion.Version)  $env:PROCESSOR_ARCHITECTURE"
  "== Running before the test (Shinoque, solubrowse)"
  Get-Process | Where-Object { $_.ProcessName -match 'shinoque|solubrowse' } |
    Select-Object ProcessName, Id, StartTime, MainWindowTitle, Path | Format-Table -AutoSize | Out-String -Width 300
  "== Who holds the ports Shinoque needs (47800-47802, 9878)"
  Get-NetTCPConnection -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in 47800, 47801, 47802, 9878 } |
    ForEach-Object {
      $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($_.OwningProcess)" -ErrorAction SilentlyContinue
      "{0}:{1} {2} pid {3} {4} | {5}" -f $_.LocalAddress, $_.LocalPort, $_.State, $_.OwningProcess, $process.Name, $process.CommandLine
    }
  "== Ports Windows has reserved (Hyper-V / WinNAT)"
  netsh interface ipv4 show excludedportrange protocol=tcp | Out-String
  "== WSL networking (.wslconfig)"
  Get-Content "$env:USERPROFILE\.wslconfig" -ErrorAction SilentlyContinue
  "== Installed apps named solubrowse/Shinoque"
  Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'shinoque|solubrowse' } | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion) $($_.InstallLocation)" }
  "== WSL"
  wsl.exe --version 2>&1 | ForEach-Object { $_ -replace "`0", '' }
  wsl.exe -l -v 2>&1 | ForEach-Object { $_ -replace "`0", '' }
  "== Inside Ubuntu: networking mode, port range, and anything on 47800-47802"
  wsl.exe --exec sh -c 'wslinfo --networking-mode 2>/dev/null; cat /proc/sys/net/ipv4/ip_local_port_range; ss -tanp 2>/dev/null | grep -E :4780[0-2] || echo nothing-inside-Ubuntu-on-47800-47802' 2>&1 |
    ForEach-Object { $_ -replace "`0", '' }
  "== SoluTerminal: where its service (port 8787) runs"
  Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($_.OwningProcess)" -ErrorAction SilentlyContinue
    "Windows: {0}:8787 pid {1} {2} | {3}" -f $_.LocalAddress, $_.OwningProcess, $process.Name, $process.ExecutablePath
  }
  "Windows data folder exists: $(Test-Path "$env:LOCALAPPDATA\soluterminal")"
  $distros = (wsl.exe --list --quiet) -replace "`0", '' | Where-Object { $_.Trim() }
  foreach ($distro in $distros) {
    "--- Ubuntu install '$($distro.Trim())'"
    # No double quotes inside: Windows PowerShell 5.1 mangles them for wsl.exe.
    wsl.exe --distribution $distro.Trim() --exec sh -c 'pgrep -ax solud | grep -v -e agent -e codex-terminal | cut -c1-160; ss -ltnp 2>/dev/null | grep :8787 || echo nothing-on-8787-here; ls -d $HOME/.local/share/soluterminal 2>/dev/null; ls $HOME/.local/share/shinoque >/dev/null 2>&1 && echo Shinoque-runtime-is-in-this-install; command -v curl >/dev/null && curl -s -m 3 http://127.0.0.1:8787/api/health | head -c 200' 2>&1 |
      ForEach-Object { $_ -replace "`0", '' }
  }
  "== Windows crash records for Shinoque (last 24 h)"
  Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddDays(-1) } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'shinoque' } | Select-Object -First 8 |
    ForEach-Object { "--- $($_.TimeCreated) $($_.ProviderName) $($_.Id)"; ($_.Message -split "`n" | Select-Object -First 14) -join "`n" }
  "== Startup steps and errors from Shinoque logs"
  Get-ChildItem "$env:APPDATA\solubrowse", "$env:LOCALAPPDATA\solubrowse", "$env:LOCALAPPDATA\shinoque" -Recurse -Filter *.log -ErrorAction SilentlyContinue |
    ForEach-Object { "--- $($_.FullName) ($($_.LastWriteTime))"; Select-String -Path $_.FullName -Pattern '\[bootstrap\]|error|panic|fail|refus|denied|unavailable|in use' | Select-Object -Last 40 | ForEach-Object { $_.Line } }
  "== Installer state"
  Get-ChildItem "$env:LOCALAPPDATA" -Recurse -Depth 2 -Filter 'installer-state*.json' -ErrorAction SilentlyContinue | ForEach-Object { "--- $($_.FullName)"; Get-Content $_.FullName -Raw }
  "== Launch test (stops any running Shinoque first)"
  Get-Process -Name Shinoque -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
  "after stopping Shinoque, 47800 is held by:"
  Get-NetTCPConnection -LocalPort 47800 -ErrorAction SilentlyContinue |
    ForEach-Object { "  pid $($_.OwningProcess) $((Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName) $($_.State)" }
  $exe = Join-Path $env:LOCALAPPDATA 'Shinoque\Shinoque.exe'
  "exe: $exe exists=$(Test-Path $exe)"
  $err = Join-Path $env:TEMP 'shinoque-launch-err.txt'
  $p = Start-Process -FilePath $exe -PassThru -RedirectStandardError $err -RedirectStandardOutput "$err.out"
  Start-Sleep -Seconds 45
  "still running after 45 s: $(-not $p.HasExited)  exit code: $(if ($p.HasExited) { $p.ExitCode })"
  "--- stderr"; Get-Content $err -ErrorAction SilentlyContinue | Select-Object -Last 60
} *>&1 | Out-File -FilePath $out -Encoding utf8
"Saved $out. Please send it to Benjamin."
