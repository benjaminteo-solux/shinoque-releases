# A developer build lives in %LOCALAPPDATA%\Shinoque when shinoque.json is there
# (only shinoque's scripts/desktop-build.sh writes it). The installer must
# refuse that folder and leave nothing behind: on 2026-10-30 a public install
# replaced a developer's own build. Runs before the real install, then clears
# the folder so the rest of the job starts from a clean machine.
param([Parameter(Mandatory)][string]$Tag, [ValidateSet('x64', 'arm64')][string]$Asset = 'x64')
$ErrorActionPreference = 'Stop'
$work = Join-Path $env:RUNNER_TEMP 'dev-folder'
New-Item -ItemType Directory -Force $work | Out-Null
gh release download $Tag --repo $env:GITHUB_REPOSITORY --dir $work --pattern "Shinoque-*.*.*-windows-$Asset-Setup.exe"
$setup = Get-ChildItem $work -Filter "Shinoque-*-windows-$Asset-Setup.exe" | Select-Object -First 1
if (-not $setup) { throw "no versioned Setup.exe in $Tag" }
$folder = Join-Path $env:LOCALAPPDATA 'Shinoque'
New-Item -ItemType Directory -Force $folder | Out-Null
Set-Content -Path (Join-Path $folder 'shinoque.json') -Value '{"wslRepo":"/home/dev/shinoque"}'
$install = Start-Process -FilePath $setup.FullName -ArgumentList '/S' -PassThru
if (-not $install.WaitForExit(300000)) { throw 'the installer did not finish within 5 minutes' }
"installer exit $($install.ExitCode) with a developer folder"
if ($install.ExitCode -eq 0) { throw 'the installer accepted a developer folder' }
$left = Get-ChildItem $folder -Name | Where-Object { $_ -ne 'shinoque.json' }
if ($left) { throw "the refused installer left files behind: $($left -join ', ')" }
if (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Shinoque') {
  throw 'the refused installer registered an uninstall entry'
}
Remove-Item -Recurse -Force $folder
'developer folder refused, nothing left behind'
