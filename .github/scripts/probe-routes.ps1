# Every way Windows can reach the installed engine in WSL, measured, so a
# "service started but is unreachable" failure names the broken route.
$distro = 'Ubuntu-24.04'
function Probe([string]$label, [scriptblock]$action) {
  try { "$label -> $(& $action)" } catch { "$label -> FAILED: $($_.Exception.Message)" }
}
$eth0 = ((wsl.exe --distribution $distro --exec sh -c "ip -4 -o addr show eth0 | awk '{print `$4}' | cut -d/ -f1") -replace "`0", '').Trim()
"== WSL"
wsl.exe --version 2>&1 | ForEach-Object { $_ -replace "`0", '' }
Get-Content "$env:USERPROFILE\.wslconfig" -ErrorAction SilentlyContinue
"eth0=$eth0"
wsl.exe --distribution $distro --exec sh -c 'hostname -I; ip route; ss -ltn | grep -E ":(47860|47876|8787)"'
"== Hyper-V firewall for WSL"
Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -ErrorAction SilentlyContinue | Format-List | Out-String
"== routes"
Probe 'inside WSL 127.0.0.1:47860' { (wsl.exe --distribution $distro --exec sh -c 'curl -s -m 5 -H "Host: 127.0.0.1:47800" http://127.0.0.1:47860/api/health') -replace "`0", '' }
Probe 'Windows -> 127.0.0.1:47860 (localhost forwarding)' { (Test-NetConnection 127.0.0.1 -Port 47860 -WarningAction SilentlyContinue).TcpTestSucceeded }
Probe "Windows -> ${eth0}:47860 (WSL address)" { (Test-NetConnection $eth0 -Port 47860 -WarningAction SilentlyContinue).TcpTestSucceeded }
Probe 'Windows -> proxy 127.0.0.1:47800' { (Invoke-WebRequest -Uri 'http://127.0.0.1:47800/api/health' -TimeoutSec 20 -UseBasicParsing).Content }
"== the app's own pipe code (pipe-probe.exe)"
$tools = Join-Path $env:RUNNER_TEMP 'tools'
New-Item -ItemType Directory -Force $tools | Out-Null
gh release download ci-tools --repo $env:GITHUB_REPOSITORY --dir $tools --pattern 'pipe-probe.exe' --clobber
$probe = Start-Process -FilePath (Join-Path $tools 'pipe-probe.exe') -ArgumentList $distro, '47860', '127.0.0.1:47800' -PassThru -NoNewWindow `
  -RedirectStandardOutput (Join-Path $tools 'probe.out') -RedirectStandardError (Join-Path $tools 'probe.err')
if (-not $probe.WaitForExit(30000)) { $probe.Kill(); 'pipe-probe: no answer within 30 s' }
Get-Content (Join-Path $tools 'probe.out'), (Join-Path $tools 'probe.err') -ErrorAction SilentlyContinue
"== same pipe by hand"
Probe 'wsl.exe stdin -> node relay' {
  $js = "const s=require('node:net').createConnection({host:'127.0.0.1',port:47860});s.on('connect',()=>{process.stdin.pipe(s);s.pipe(process.stdout)});s.on('error',e=>{console.error(e.message);process.exit(1)})"
  ("GET /api/health HTTP/1.1`r`nHost: 127.0.0.1:47800`r`nConnection: close`r`n`r`n" | wsl.exe --distribution $distro --exec sh -c 'exec "$HOME/.local/share/shinoque/current/runtime/bin/node" -e "$1"' sh $js) -join ' '
}
exit 0
