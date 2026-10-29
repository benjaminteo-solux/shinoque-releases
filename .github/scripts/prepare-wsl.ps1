# A tester's PC: WSL2, Ubuntu 24.04, an ordinary (non-root) default user.
$ErrorActionPreference = 'Stop'
wsl.exe --version
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
