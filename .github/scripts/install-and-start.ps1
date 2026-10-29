# Install one release and require the window to stay up, show the real app
# and the engine to answer as that release.
#   -Mode fresh     silent install, then open it from its install folder
#   -Mode previous  an earlier (possibly broken) release, only to set up an update
#   -Mode update    what the in-app updater does: the app ends, the installer runs
#                   with /P /R /UPDATE and relaunches it
param(
  [Parameter(Mandatory)][string]$Tag,
  [ValidateSet('fresh', 'previous', 'update')][string]$Mode = 'fresh'
)
$ErrorActionPreference = 'Stop'
$work = Join-Path $env:RUNNER_TEMP $Mode
New-Item -ItemType Directory -Force $work | Out-Null
gh release download $Tag --repo $env:GITHUB_REPOSITORY --dir $work --pattern 'Shinoque-*.*.*-windows-x64-Setup.exe'
$setup = Get-ChildItem $work -Filter 'Shinoque-*-windows-x64-Setup.exe' | Select-Object -First 1
if (-not $setup) { throw "no versioned Setup.exe in $Tag" }
$version = [regex]::Match($setup.Name, 'Shinoque-(\d+\.\d+\.\d+)-').Groups[1].Value
"== $Mode $Tag version $version"
# 0.2.4 moved the installed proxy out of Windows' reserved port ranges.
$port = if ([version]$version -lt [version]'0.2.4') { 14800 } else { 47800 }
$exe = Join-Path $env:LOCALAPPDATA 'Shinoque\Shinoque.exe'
$started = Get-Date

if ($Mode -eq 'update') {
  # The updater ends the app itself before its installer replaces the files.
  Get-Process Shinoque -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
  $install = Start-Process -FilePath $setup.FullName -ArgumentList '/P', '/R', '/UPDATE' -PassThru -Wait
  "installer exit $($install.ExitCode)"
  if ($install.ExitCode -ne 0) { throw "update installer failed ($($install.ExitCode))" }
  $app = $null
  for ($i = 0; $i -lt 30 -and -not $app; $i++) {
    Start-Sleep -Seconds 2
    $app = Get-Process Shinoque -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -gt $started } | Select-Object -First 1
  }
  if (-not $app) { throw 'the installer did not relaunch Shinoque after the update' }
  'the installer relaunched Shinoque'
} else {
  Get-Process Shinoque -ErrorAction SilentlyContinue | Stop-Process -Force
  $install = Start-Process -FilePath $setup.FullName -ArgumentList '/S' -PassThru -Wait
  "installer exit $($install.ExitCode)"
  if ($install.ExitCode -ne 0) { throw "installer failed ($($install.ExitCode))" }
  $app = Start-Process -FilePath $exe -PassThru
}

if ($Mode -eq 'previous') {
  Start-Sleep -Seconds 90
  "previous release opened; still running: $(-not $app.HasExited)"
  return
}

$deadline = (Get-Date).AddMinutes(20)
$healthy = $false
while ((Get-Date) -lt $deadline) {
  if ($app.HasExited) {
    $report = Join-Path $env:LOCALAPPDATA 'Shinoque\startup-error.log'
    if (Test-Path $report) { Get-Content $report }
    throw ("Shinoque exited during startup with 0x{0:X}" -f $app.ExitCode)
  }
  try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 5
    if ($health.name -eq 'shinoqued' -and $health.releaseId -eq $version) { $healthy = $true; break }
    "health answered for release '$($health.releaseId)'; waiting for $version"
  } catch {
    "waiting for the engine: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds 10
}
if (-not $healthy) { throw "the engine never answered as $version within 20 minutes" }
"engine healthy as $version after $([int]((Get-Date) - $started).TotalSeconds) s"

# The window shares its title with the starting and error screens, so read
# what it actually shows through UI Automation.
Start-Sleep -Seconds 30
$app.Refresh()
if ($app.HasExited) { throw ("Shinoque exited after starting (0x{0:X})" -f $app.ExitCode) }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$root = [System.Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
$names = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
  ForEach-Object { $_.Current.Name } | Where-Object { $_ }
$evidence = Join-Path $env:GITHUB_WORKSPACE 'evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
$names | Out-File (Join-Path $evidence "window-text-$Mode.txt")
$text = $names -join "`n"
"window shows $($names.Count) named elements"
if ($text -match 'could not start|Retry after') { throw "the window shows an error: $(($names | Select-String 'could not start|Retry after') -join ' / ')" }
if ($text -notmatch 'Settings') { throw 'the window does not show the app yet (no Settings entry)' }

# An update keeps the user's data and switches the WSL release.
if ($Mode -eq 'update') {
  $state = Get-Content (Join-Path $env:LOCALAPPDATA 'Shinoque\installer-state.json') -Raw | ConvertFrom-Json
  if ($state.releaseId -ne $version) { throw "installer state still names $($state.releaseId)" }
  $wsl = (wsl.exe --distribution Ubuntu-24.04 --exec sh -c 'readlink ~/.local/share/shinoque/current; test -d ~/.local/share/shinoque/data && echo data-kept') -replace "`0", ''
  "$wsl"
  if ($wsl -notmatch "releases/$version" -or $wsl -notmatch 'data-kept') { throw 'the WSL release did not switch or data was lost' }
}
$crashes = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; StartTime = $started } -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match 'Shinoque' }
if ($crashes) { $crashes | ForEach-Object { $_.Message }; throw 'Windows recorded a Shinoque crash' }
"$Mode passed"
