# Everything needed to understand a failure without access to the machine.
$out = Join-Path $env:GITHUB_WORKSPACE 'evidence'
New-Item -ItemType Directory -Force $out | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
try {
  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  [System.Drawing.Graphics]::FromImage($bitmap).CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
  $bitmap.Save((Join-Path $out 'screen.png'))
} catch { "screenshot failed: $_" | Out-File (Join-Path $out 'screen-error.txt') }
& {
  "== processes"; Get-Process | Where-Object { $_.ProcessName -match 'shinoque|msedgewebview2|wsl' } | Select-Object ProcessName, Id, MainWindowTitle | Format-Table -AutoSize | Out-String -Width 200
  "== ports"; Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 9878, 47800, 47801, 47802 } | Select-Object LocalAddress, LocalPort, OwningProcess | Format-Table | Out-String
  "== reserved port ranges"; netsh interface ipv4 show excludedportrange protocol=tcp
  "== dynamic range"; netsh interface ipv4 show dynamicport tcp
  "== crash records"; Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1001 } -MaxEvents 20 -ErrorAction SilentlyContinue | ForEach-Object { "--- $($_.TimeCreated)"; $_.Message }
} *>&1 | Out-File (Join-Path $out 'windows.txt')
foreach ($file in "$env:LOCALAPPDATA\Shinoque\startup-error.log", "$env:LOCALAPPDATA\Shinoque\installer-state.json") {
  if (Test-Path $file) { Copy-Item $file $out }
}
Get-ChildItem "$env:APPDATA\solubrowse" -Recurse -Filter *.log -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName (Join-Path $out ("desktop-" + $_.Name)) }
wsl.exe --distribution Ubuntu-24.04 --exec sh -c 'cd ~/.local/share/shinoque/data/logs 2>/dev/null && tail -n 200 *.log' 2>&1 | Out-File (Join-Path $out 'wsl-logs.txt')
