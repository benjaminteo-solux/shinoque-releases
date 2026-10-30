# Another program on ports Shinoque would use (Jiazhen's PC kept 47800 busy).
# Holds loopback listeners for the rest of the job; Shinoque must start anyway
# on another port block.
param([Parameter(Mandatory)][string]$Ports)
$ErrorActionPreference = 'Stop'
$list = $Ports.Split(',') | ForEach-Object { [int]$_.Trim() }
$code = "`$held = @(); foreach (`$port in @($($list -join ','))) { `$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, `$port); `$listener.Start(); `$held += `$listener }; Start-Sleep -Seconds 7200"
Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-Command', $code -WindowStyle Hidden
Start-Sleep -Seconds 5
foreach ($port in $list) {
  $holder = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $holder) { throw "could not hold port $port" }
  "port $port held by pid $($holder.OwningProcess)"
}
