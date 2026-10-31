# Window mode (0.2.13 and later): a PC set to open another computer's
# Shinoque must never set up WSL or its own engine, and its bundled setup
# page must be able to call the app (its own local capability). The window's
# title names the setup step once the page has heard back from the app.
param([Parameter(Mandatory)][string]$Tag)
$ErrorActionPreference = 'Stop'
$work = Join-Path $env:RUNNER_TEMP 'window'
New-Item -ItemType Directory -Force $work | Out-Null
gh release download $Tag --repo $env:GITHUB_REPOSITORY --dir $work --pattern 'Shinoque-*.*.*-windows-x64-Setup.exe'
$setup = Get-ChildItem $work -Filter 'Shinoque-*-windows-x64-Setup.exe' | Select-Object -First 1
if (-not $setup) { throw "no versioned Setup.exe in $Tag" }
$install = Start-Process -FilePath $setup.FullName -ArgumentList '/S' -PassThru -Wait
if ($install.ExitCode -ne 0) { throw "installer failed ($($install.ExitCode))" }

# What choosing a computer and pressing Open leaves behind, before any pairing.
$state = Join-Path $env:LOCALAPPDATA 'Shinoque\window-home.json'
@{
  active = $true; machine = ''; backend = ''; name = ''
  pairing = @{ id = ''; publicKey = ''; daemonIdentity = ''; pinnedIdentity = ''; code = ''; status = ''; confirmed = $false }
} | ConvertTo-Json | Set-Content -Encoding utf8 $state

$exe = Join-Path $env:LOCALAPPDATA 'Shinoque\Shinoque.exe'
$app = Start-Process -FilePath $exe -PassThru
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$expected = 'shinoque · Open a home you already have'
$deadline = (Get-Date).AddMinutes(3)
$title = ''
while ((Get-Date) -lt $deadline) {
  if ($app.HasExited) { throw ("Shinoque exited with 0x{0:X}" -f $app.ExitCode) }
  $app.Refresh()
  if ($app.MainWindowHandle -ne 0) {
    $title = [System.Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle).Current.Name
    if ($title -eq $expected) { break }
  }
  Start-Sleep -Seconds 3
}
"window title: '$title'"
if ($title -ne $expected) {
  # What the window shows, for the evidence (WebView2 text is not in UIA).
  Add-Type -AssemblyName System.Drawing, System.Windows.Forms
  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $shot = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  [System.Drawing.Graphics]::FromImage($shot).CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
  $evidence = Join-Path $env:GITHUB_WORKSPACE 'evidence'
  New-Item -ItemType Directory -Force $evidence | Out-Null
  $shot.Save((Join-Path $evidence 'window-mode.png'))
  $report = Join-Path $env:LOCALAPPDATA 'Shinoque\startup-error.log'
  if (Test-Path $report) { Get-Content $report }
  throw "the setup page did not reach its first step (title '$title')"
}

# Nothing of a local engine: no release unpacked into WSL.
$releases = (wsl.exe --distribution Ubuntu-24.04 --exec sh -c 'ls ~/.local/share/shinoque/releases 2>/dev/null | wc -l') -replace "`0", '' -join ''
"WSL releases: $releases"
if ([int]$releases -ne 0) { throw 'window mode set up a local engine in WSL' }
'window mode passed'
exit 0
