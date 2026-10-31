# Another program on ports Shinoque would use (Jiazhen's PC kept 47800 busy).
# Holds loopback listeners for the rest of the job; Shinoque must start anyway
# on another port block.
param([Parameter(Mandatory)][string]$Ports, [int]$Seconds = 7200)
$ErrorActionPreference = 'Stop'
$list = $Ports.Split(',') | ForEach-Object { [int]$_.Trim() }
# A script file, not an inline command: Start-Process does not quote arguments.
$holder = Join-Path ([IO.Path]::GetTempPath()) 'shinoque-hold-ports.ps1'
@"
`$held = foreach (`$port in @($($list -join ','))) {
  `$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, `$port)
  `$listener.Start()
  `$listener
}
Start-Sleep -Seconds $Seconds
"@ | Set-Content -Path $holder -Encoding ascii
Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holder -WindowStyle Hidden
foreach ($port in $list) {
  $owner = $null
  for ($i = 0; $i -lt 30 -and -not $owner; $i++) {
    Start-Sleep -Seconds 1
    $owner = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  if (-not $owner) { throw "could not hold port $port" }
  "port $port held by pid $($owner.OwningProcess)"
}
