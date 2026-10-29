# Install one release silently, open it the way a tester does, and require the
# window to stay up and the engine to answer as that release.
param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Label)
$ErrorActionPreference = 'Stop'
$work = Join-Path $env:RUNNER_TEMP $Label
New-Item -ItemType Directory -Force $work | Out-Null
gh release download $Tag --repo $env:GITHUB_REPOSITORY --dir $work --pattern 'Shinoque-*.*.*-windows-x64-Setup.exe'
$setup = Get-ChildItem $work -Filter 'Shinoque-*-windows-x64-Setup.exe' | Select-Object -First 1
if (-not $setup) { throw "no versioned Setup.exe in $Tag" }
$version = [regex]::Match($setup.Name, 'Shinoque-(\d+\.\d+\.\d+)-').Groups[1].Value
"== $Label $Tag version $version"

# An upgrade replaces files the running app holds, as the in-app updater does.
Get-Process Shinoque -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$started = Get-Date
$install = Start-Process -FilePath $setup.FullName -ArgumentList '/S' -PassThru -Wait
"installer exit $($install.ExitCode)"
if ($install.ExitCode -ne 0) { throw "installer failed ($($install.ExitCode))" }

$exe = Join-Path $env:LOCALAPPDATA 'Shinoque\Shinoque.exe'
$app = Start-Process -FilePath $exe -PassThru
$deadline = (Get-Date).AddMinutes(20)
$healthy = $false
while ((Get-Date) -lt $deadline) {
  if ($app.HasExited) {
    $report = Join-Path $env:LOCALAPPDATA 'Shinoque\startup-error.log'
    if (Test-Path $report) { Get-Content $report }
    throw ("Shinoque exited during startup with 0x{0:X}" -f $app.ExitCode)
  }
  try {
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:47800/api/health' -TimeoutSec 5
    if ($health.name -eq 'shinoqued' -and $health.releaseId -eq $version) { $healthy = $true; break }
    "health answered for release '$($health.releaseId)'; waiting for $version"
  } catch {
    "waiting for the engine: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds 10
}
if (-not $healthy) { throw "the engine never answered as $version within 20 minutes" }
"engine healthy as $version after $([int]((Get-Date) - $started).TotalSeconds) s"

# Settle, then require a visible window and no crash reports for this run.
Start-Sleep -Seconds 20
$app.Refresh()
if ($app.HasExited) { throw ("Shinoque exited after starting (0x{0:X})" -f $app.ExitCode) }
"window: '$($app.MainWindowTitle)'"
if ($app.MainWindowTitle -ne 'shinoque') { throw 'no Shinoque window is showing' }
$crashes = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000; StartTime = $started } -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match 'Shinoque' }
if ($crashes) { $crashes | ForEach-Object { $_.Message }; throw 'Windows recorded a Shinoque crash' }
"$Label passed"
