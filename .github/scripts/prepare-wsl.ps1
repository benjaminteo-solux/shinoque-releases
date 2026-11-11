# A tester's PC: WSL2, Ubuntu 24.04, an ordinary (non-root) default user, and
# the WSL networking mode under test (testers use both nat and mirrored).
param([ValidateSet('nat', 'mirrored')][string]$Networking = 'nat')
$ErrorActionPreference = 'Stop'
# This rewrites .wslconfig and can change every adapter's DNS: never anywhere but a thrown-away GitHub runner.
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
  throw 'prepare-wsl.ps1 runs only on a GitHub-hosted runner'
}
if ($Networking -eq 'mirrored') {
  "[wsl2]`nnetworkingMode=mirrored`n" | Set-Content -Path "$env:USERPROFILE\.wslconfig" -Encoding ascii
  'WSL networking: mirrored'
}
wsl.exe --version
# On 11-11 the runners' Azure DNS failed for the whole ubuntu.com zone while public resolvers answered, so
# wsl --install could not download Ubuntu. If the runner's own DNS can't resolve the Ubuntu hosts, point this
# runner at 1.1.1.1 and 8.8.8.8. Downloads stay HTTPS-verified and apt stays signature-checked; only name
# lookups move.
$ubuntuHosts = 'releases.ubuntu.com', 'cdimage.ubuntu.com', 'archive.ubuntu.com'
$unresolved = @($ubuntuHosts | Where-Object { -not (Resolve-DnsName -Name $_ -DnsOnly -ErrorAction SilentlyContinue) })
if ($unresolved.Count) {
  "DNS: the runner's resolver can't resolve $($unresolved -join ', '); using 1.1.1.1 and 8.8.8.8 on this runner"
  foreach ($nic in Get-NetAdapter | Where-Object Status -eq 'Up') {
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses '1.1.1.1', '8.8.8.8'
  }
  Clear-DnsClientCache
  $still = @($ubuntuHosts | Where-Object { -not (Resolve-DnsName -Name $_ -DnsOnly -ErrorAction SilentlyContinue) })
  if ($still.Count) { throw "DNS: still unresolved through public resolvers: $($still -join ', ')" }
  'DNS: Ubuntu hosts resolve through public resolvers'
} else {
  'DNS: the runner resolves the Ubuntu hosts itself'
}
wsl.exe --install --distribution Ubuntu-24.04 --web-download --no-launch
if ($LASTEXITCODE -ne 0) { throw "wsl --install failed ($LASTEXITCODE)" }
# Newer WSL registers the distribution at install; older builds need its launcher once.
$names = (wsl.exe --list --quiet) -replace "`0", '' | Where-Object { $_ }
if ($names -notcontains 'Ubuntu-24.04') {
  $launcher = Get-Command ubuntu2404.exe -ErrorAction SilentlyContinue
  if (-not $launcher) { throw 'Ubuntu-24.04 is not registered and has no launcher' }
  & $launcher.Source install --root
}
$setup = @'
set -e
id tester >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo tester
echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester
printf '[user]\ndefault=tester\n' > /etc/wsl.conf
'@
# PowerShell here-strings carry CRLF; bash would read "set -e\r" and stop.
wsl.exe --distribution Ubuntu-24.04 --user root --exec bash -c ($setup -replace "`r", '')
if ($LASTEXITCODE -ne 0) { throw 'creating the Ubuntu user failed' }
wsl.exe --terminate Ubuntu-24.04
wsl.exe --list --verbose
wsl.exe --distribution Ubuntu-24.04 --exec sh -c 'echo "user=$(id -un) uid=$(id -u) $(. /etc/os-release; echo $VERSION_ID) $(uname -m)"'
$uid = ((wsl.exe --distribution Ubuntu-24.04 --exec id -u) -replace "`0", '').Trim()
if ($uid -eq '0') { throw 'the default Ubuntu user is still root; a tester has an ordinary user' }
