# Every way Windows can reach the installed engine in WSL, measured, so a
# "service started but is unreachable" failure names the broken route.
$distro = 'Ubuntu-24.04'
function Probe([string]$label, [scriptblock]$action) {
  try { "$label -> $(& $action)" } catch { "$label -> FAILED: $($_.Exception.Message)" }
}
$eth0 = "$((wsl.exe --distribution $distro --exec sh -c "hostname -I") -replace "`0", '')".Trim().Split(' ')[0]
"networking mode: $("$((wsl.exe --distribution $distro --exec wslinfo --networking-mode) -replace "`0", '')".Trim())"
"== WSL"
wsl.exe --version 2>&1 | ForEach-Object { $_ -replace "`0", '' }
Get-Content "$env:USERPROFILE\.wslconfig" -ErrorAction SilentlyContinue
"eth0=$eth0"
wsl.exe --distribution $distro --exec sh -c 'hostname -I; ip -4 -o addr; ip route; ss -ltn | grep -E ":(47860|47876|8787)"'
"== Hyper-V firewall for WSL"
Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -ErrorAction SilentlyContinue | Format-List | Out-String
"== routes"
Probe 'inside WSL 127.0.0.1:47860' { (wsl.exe --distribution $distro --exec sh -c 'curl -s -m 5 -H "Host: 127.0.0.1:47800" http://127.0.0.1:47860/api/health') -replace "`0", '' }
Probe 'Windows -> 127.0.0.1:47860 (localhost forwarding)' { (Test-NetConnection 127.0.0.1 -Port 47860 -WarningAction SilentlyContinue).TcpTestSucceeded }
Probe "Windows -> ${eth0}:47860 (WSL address)" { (Test-NetConnection $eth0 -Port 47860 -WarningAction SilentlyContinue).TcpTestSucceeded }
Probe 'Windows -> proxy 127.0.0.1:47800' { (Invoke-WebRequest -Uri 'http://127.0.0.1:47800/api/health' -TimeoutSec 20 -UseBasicParsing).Content }
"== SoluTerminal in WSL, then one request through the Code proxy"
$listening = $false
for ($i = 0; $i -lt 36 -and -not $listening; $i++) {
  $listening = [bool]((wsl.exe --distribution $distro --exec sh -c 'ss -ltn | grep ":8787 "') -replace "`0", '')
  if (-not $listening) { Start-Sleep -Seconds 5 }
}
"8787 listening in WSL: $listening"
if (-not $listening) {
  # A runner may have no SoluTerminal. A stand-in on the same port, with a fake
  # token, still shows the forwarder's owner and exercises the Code proxy's check.
  "no SoluTerminal here: using a stand-in on 8787"
  # Held by a wsl.exe that stays running: one started in the background of a finished wsl.exe dies.
  $server = "require('node:http').createServer((q,s)=>s.end('stand-in')).listen(8787,'127.0.0.1')"
  $server | wsl.exe --distribution $distro --exec sh -c 'mkdir -p "$HOME/.solu"; cat > "$HOME/.solu/stand-in.js"; [ -s "$HOME/.solu/token" ] || printf %064d 0 > "$HOME/.solu/token"'
  $wslHome = "$((wsl.exe --distribution $distro --exec sh -c 'printf %s "$HOME"') -replace "`0", '')".Trim()
  Start-Process wsl.exe -NoNewWindow -RedirectStandardOutput (Join-Path $env:RUNNER_TEMP 'stand-in.out') -RedirectStandardError (Join-Path $env:RUNNER_TEMP 'stand-in.err') -ArgumentList @('--distribution', $distro, '--exec', "$wslHome/.local/share/shinoque/current/runtime/bin/node", "$wslHome/.solu/stand-in.js") | Out-Null
  # The forwarder notices a new WSL listener by polling.
  Start-Sleep -Seconds 20
  # A stand-in that died and a forwarder that missed it look alike from Windows.
  "stand-in, 20 s on:"
  wsl.exe --distribution $distro --exec sh -c 'ss -ltn | grep ":8787 " || echo "nothing listens on 8787 in WSL"; curl -s -m 5 http://127.0.0.1:8787/ || echo "no answer in WSL"' 2>&1 | ForEach-Object { "$_" -replace "`0", '' }
}
Probe 'Windows -> Code proxy 127.0.0.1:47801' { (Invoke-WebRequest -Uri 'http://127.0.0.1:47801/api/health' -TimeoutSec 20 -UseBasicParsing).StatusCode }
"== who holds the Windows end of each forwarded port (this repo is public: runner paths only)"
"whoami: $(whoami)"
foreach ($port in 47860, 8787) {
  # Held open during the read, as the Code proxy's own connection is when it looks up the owner.
  $held = [System.Net.Sockets.TcpClient]::new()
  try {
    $held.Connect('127.0.0.1', $port)
    "port ${port}: connected from $($held.Client.LocalEndPoint)"
  } catch {
    "port ${port}: no connection from Windows"
  }
  $rows = @(Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue)
  if (-not $rows) { "port ${port}: no Windows row" }
  foreach ($row in $rows) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($row.OwningProcess)" -ErrorAction SilentlyContinue
    $user = if ($process) { $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner; "$($owner.Domain)\$($owner.User)" } else { 'unknown' }
    "port ${port}: $($row.State) $($row.LocalAddress):$($row.LocalPort) from $($row.RemoteAddress):$($row.RemotePort) pid=$($row.OwningProcess) image=$($process.ExecutablePath) user=$user"
  }
  $held.Dispose()
}
"== the app's own pipe code (pipe-probe.exe)"
$tools = Join-Path $env:RUNNER_TEMP 'tools'
New-Item -ItemType Directory -Force $tools | Out-Null
gh release download ci-tools --repo $env:GITHUB_REPOSITORY --dir $tools --pattern 'pipe-probe.exe' --clobber
$probe = Start-Process -FilePath (Join-Path $tools 'pipe-probe.exe') -ArgumentList $distro, '47860', '127.0.0.1:47800' -PassThru -NoNewWindow `
  -RedirectStandardOutput (Join-Path $tools 'probe.out') -RedirectStandardError (Join-Path $tools 'probe.err')
if (-not $probe.WaitForExit(30000)) { $probe.Kill(); 'pipe-probe: no answer within 30 s' }
Get-Content (Join-Path $tools 'probe.out'), (Join-Path $tools 'probe.err') -ErrorAction SilentlyContinue
"== app startup log so far"
Get-ChildItem "$env:APPDATA\solubrowse" -Recurse -Filter solubrowse.log -ErrorAction SilentlyContinue | ForEach-Object { Select-String -Path $_.FullName -Pattern '\[bootstrap\]|\[code-proxy\]' | ForEach-Object { $_.Line } }
"== same pipe by hand"
Probe 'wsl.exe stdin -> node relay' {
  $js = "const s=require('node:net').createConnection({host:'127.0.0.1',port:47860});s.on('connect',()=>{process.stdin.pipe(s);s.pipe(process.stdout)});s.on('error',e=>{console.error(e.message);process.exit(1)})"
  ("GET /api/health HTTP/1.1`r`nHost: 127.0.0.1:47800`r`nConnection: close`r`n`r`n" | wsl.exe --distribution $distro --exec sh -c 'exec "$HOME/.local/share/shinoque/current/runtime/bin/node" -e "$1"' sh $js) -join ' '
}
exit 0
