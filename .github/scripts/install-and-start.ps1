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
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
# Every top-level window's own text, so a dialog waiting for a click is named
# in the log instead of hanging the job silently.
function Show-Windows {
  $desktop = [System.Windows.Automation.AutomationElement]::RootElement
  foreach ($window in $desktop.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    "--- window '$($window.Current.Name)' (pid $($window.Current.ProcessId))"
    $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
      ForEach-Object { $_.Current.Name } | Where-Object { $_ } | Select-Object -First 25 | ForEach-Object { "    $_" }
  }
}
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
  # 0.2.3 on a fresh PC is still stuck in setup (its solud download), and that
  # wsl.exe child read-locks the bundled payload the installer must replace.
  # On a tester's PC that step finished long ago.
  Get-Process wsl -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
  $install = Start-Process -FilePath $setup.FullName -ArgumentList '/P', '/R', '/UPDATE' -PassThru
  if (-not $install.WaitForExit(600000)) {
    Show-Windows
    throw 'the update installer did not finish within 10 minutes (windows above)'
  }
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
  # Earlier releases may crash on their first launches (0.2.3 did, until its
  # shortcuts were stamped). Relaunch until it runs as itself, then leave a
  # marker in its data so the update must keep it.
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    $until = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $until -and -not $app.HasExited) {
      try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 5
        if ($health.releaseId -eq $version) {
          wsl.exe --distribution Ubuntu-24.04 --exec sh -c 'echo kept > ~/.local/share/shinoque/data/ci-update-marker'
          "previous $version running after $attempt launch(es); marker written"
          "PREVIOUS_READY=1" | Out-File -Append $env:GITHUB_ENV
          return
        }
      } catch {}
      Start-Sleep -Seconds 10
    }
    "launch $attempt did not come up (exited: $($app.HasExited)); relaunching"
    Get-Process Shinoque -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $app = Start-Process -FilePath $exe -PassThru
  }
  "::warning::previous release $version never came up; the update test is inconclusive"
  "PREVIOUS_READY=0" | Out-File -Append $env:GITHUB_ENV
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
# WebView2 page text is not in the UI Automation tree, but the app titles its
# window after the open space ("shinoque · Home"); the starting and error
# screens are titled plain "shinoque".
# A slow start still passes if the app shows within five more minutes; the log
# records how long it took.
$appShown = { $script:names = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name } | Where-Object { $_ }; [bool]($script:names | Where-Object { $_ -match '^shinoque · ' }) }
$waitUntil = (Get-Date).AddMinutes(5)
while (-not (& $appShown) -and (Get-Date) -lt $waitUntil) { Start-Sleep -Seconds 10 }
if (-not (& $appShown)) { throw "the window does not show the app yet (titles: $($names -join ' / '))" }
"app shown after $([int]((Get-Date) - $started).TotalSeconds) s"

# An update keeps the user's data and switches the WSL release.
if ($Mode -eq 'update') {
  $state = Get-Content (Join-Path $env:LOCALAPPDATA 'Shinoque\installer-state.json') -Raw | ConvertFrom-Json
  if ($state.releaseId -ne $version) { throw "installer state still names $($state.releaseId)" }
  $wsl = (wsl.exe --distribution Ubuntu-24.04 --exec sh -c 'readlink ~/.local/share/shinoque/current; cat ~/.local/share/shinoque/data/ci-update-marker 2>/dev/null') -replace "`0", ''
  "$wsl"
  if ($wsl -notmatch "releases/$version") { throw 'the WSL release did not switch to the update' }
  # A previous release that never ran (0.2.3 on a fresh PC, like the testers')
  # left no data to keep; the update still has to bring the app up.
  if ($env:PREVIOUS_READY -eq '1') {
    if ($wsl -notmatch 'kept') { throw "the update lost the previous release's data" }
  } else {
    '::warning::the previous release never ran, so data survival was not checked'
  }
}
$crashes = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; StartTime = $started } -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match 'Shinoque' }
if ($crashes) { $crashes | ForEach-Object { $_.Message }; throw 'Windows recorded a Shinoque crash' }
"$Mode passed"
# A native probe above may leave a non-zero exit code; every check has passed.
exit 0
