# The ARM installer carries only the ARM64 WSL runtime. On an x64 PC it must
# refuse and leave nothing behind; real ARM installs are checked on a Surface
# (GitHub's ARM runners have no WSL).
param([Parameter(Mandatory)][string]$Tag)
$ErrorActionPreference = 'Stop'
$work = Join-Path $env:RUNNER_TEMP 'arm64'
New-Item -ItemType Directory -Force $work | Out-Null
gh release download $Tag --repo $env:GITHUB_REPOSITORY --dir $work --pattern 'Shinoque-*.*.*-windows-arm64-Setup.exe'
$setup = Get-ChildItem $work -Filter 'Shinoque-*-windows-arm64-Setup.exe' | Select-Object -First 1
if (-not $setup) { throw "no versioned ARM Setup.exe in $Tag" }
"ARM installer: $($setup.Name), $([int]($setup.Length / 1MB)) MB"
$install = Start-Process -FilePath $setup.FullName -ArgumentList '/S' -PassThru
if (-not $install.WaitForExit(300000)) { throw 'the installer did not finish within 5 minutes' }
"installer exit $($install.ExitCode) on an x64 PC"
if ($install.ExitCode -eq 0) { throw 'the ARM installer accepted an x64 PC' }
if (Test-Path (Join-Path $env:LOCALAPPDATA 'Shinoque\Shinoque.exe')) { throw 'the refused installer left Shinoque.exe behind' }
if (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Shinoque') {
  throw 'the refused installer registered an uninstall entry'
}
'ARM installer refused this x64 PC, nothing left behind'
