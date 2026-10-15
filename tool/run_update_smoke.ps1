param(
  [ValidateSet('zip','exe','both')][string]$Format = 'both',
  [string]$Iscc = 'ISCC.exe',
  [string]$Flutter = 'flutter'
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ($Format -ne 'zip' -and -not (Get-Command $Iscc -ErrorAction SilentlyContinue)) { throw 'EXE smoke testing requires the prepared Inno Setup compiler.' }
# Always build the isolated entrypoint here: a previous production build must never be launched by a test.
Push-Location $workspace
try {
  & $Flutter build windows --release --no-pub --target=tool/update_smoke.dart
  if ($LASTEXITCODE -ne 0) { throw 'Isolated smoke app compilation failed.' }
} finally { Pop-Location }
$source = [IO.Path]::GetFullPath((Join-Path $workspace 'build\windows\x64\runner\Release'))
foreach ($selectedFormat in $(if ($Format -eq 'both') { @('zip','exe') } else { @($Format) })) {
$fixture = Join-Path $workspace ('build\update-smoke-' + [Guid]::NewGuid().ToString('N'))
$current = Join-Path $fixture 'current'
$staged = Join-Path $fixture 'staged'
$cache = Join-Path $fixture 'cache'
foreach ($directory in @($current,$staged,$cache)) { $null = New-Item -ItemType Directory -Path $directory }
$sources = @(Get-Content -LiteralPath (Join-Path $workspace 'build\windows\x64\install_manifest.txt'))
$sources += @('qq_bot_manager.exe','WebView2Loader.dll','native_assets.json') | ForEach-Object { Join-Path $source $_ }
foreach ($file in ($sources | Select-Object -Unique)) {
  $resolved = [IO.Path]::GetFullPath($file)
  if (-not $resolved.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Runtime source outside Release.' }
  $relative = $resolved.Substring($source.Length+1)
  foreach ($destination in $(if ($selectedFormat -eq 'zip') { @($current,$staged) } else { @($staged) })) {
    $target = Join-Path $destination $relative
    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
    Copy-Item -LiteralPath $resolved -Destination $target
  }
}
$qaIdentity = [Guid]::NewGuid().ToString('N')
& (Join-Path $PSScriptRoot 'copy_windows_crt.ps1') -Destination $staged
if ($selectedFormat -eq 'zip') { & (Join-Path $PSScriptRoot 'copy_windows_crt.ps1') -Destination $current }
$testRegistry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\cn.uuze.botmanager.qa-' + $qaIdentity + '_is1'
function Compile-TestInstaller([string]$Version, [int]$Number) {
  & $Iscc /Q "/DAppFiles=$staged" "/DAppOutput=$cache" "/DAppVersion=$Version" "/DBuildNumber=$Number" "/DAppIcon=$(Join-Path $workspace 'windows\runner\resources\app_icon.ico')" "/DQaIdentity=$qaIdentity" (Join-Path $workspace 'scripts\windows-installer.iss')
  if ($LASTEXITCODE -ne 0) { throw 'Test installer compilation failed.' }
  return (Join-Path $cache "qqbotmanager-windows-v$Version-build$Number-setup.exe")
}
try {
if ($selectedFormat -eq 'exe') {
  # Fresh install uses a GUID-only test identity and no shortcuts or automatic launch.
  [IO.File]::WriteAllText((Join-Path $staged 'updated-payload.txt'),'baseline payload')
  $baseline = Compile-TestInstaller '1.3.0' 1
  $initial = Start-Process -FilePath $baseline -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/DIR="'+$current+'"'),('/LOG="'+(Join-Path $cache 'initial-install.log')+'"')) -WindowStyle Hidden -PassThru
  $initial.WaitForExit()
  if ($initial.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $testRegistry)) { throw 'Fresh test installation/registration failed.' }
  if ((Get-Content -LiteralPath (Join-Path $current 'updated-payload.txt') -Raw) -ne 'baseline payload') { throw 'Baseline installation payload mismatch.' }
}
# Fixture outputs, not source/configuration files; all paths are in this fresh GUID directory.
[IO.File]::WriteAllText((Join-Path $staged 'updated-payload.txt'),'updated payload')
[IO.File]::WriteAllText((Join-Path $current 'keep-me.txt'),'preserve unrelated fixture')
$package = Join-Path $cache ('package.' + $selectedFormat)
if ($selectedFormat -eq 'zip') { Compress-Archive -Path (Join-Path $staged '*') -DestinationPath $package }
else { Copy-Item -LiteralPath (Compile-TestInstaller '1.3.1' 2) -Destination $package }
$result = Join-Path $fixture 'smoke-result.json'
$state = @{phase='before-update';format=$selectedFormat;cache=$cache;package=$package;result=$result} | ConvertTo-Json -Compress
[IO.File]::WriteAllText((Join-Path $current '.qqm-smoke.json'),$state,[Text.UTF8Encoding]::new($false))
$process = Start-Process -FilePath (Join-Path $current 'qq_bot_manager.exe') -WorkingDirectory $fixture -WindowStyle Hidden -PassThru
$until = [DateTime]::UtcNow.AddSeconds(100)
while (-not (Test-Path -LiteralPath $result) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 250 }
if (-not (Test-Path -LiteralPath $result)) { throw ('No result; inspect task-owned fixture ' + $fixture) }
$value = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
Get-Content -LiteralPath $result
Get-Content -LiteralPath (Join-Path $cache 'result.json') -ErrorAction SilentlyContinue
Write-Output ('fixture=' + $fixture)
if (-not $value.passed) { exit 1 }
if (-not $process.WaitForExit(10000)) { throw 'Original smoke process did not exit.' }
$process.Refresh(); Write-Output ('original_exit=' + $process.ExitCode)
if ($selectedFormat -eq 'exe') {
  $registration = Get-ItemProperty -LiteralPath $testRegistry
  if ($registration.DisplayVersion -ne '1.3.1' -or $registration.InstallLocation.TrimEnd('\') -ne $current) { throw 'Update did not preserve the installation location/identity.' }
  Write-Output 'PASS EXE: fresh installation, silent replacement, preserved location, relaunch and unrelated data.'
}
} finally {
  if ($selectedFormat -eq 'exe' -and (Test-Path -LiteralPath $testRegistry)) {
    # Only processes at this newly created GUID fixture path are considered, never the user's real app.
    $testExe = Join-Path $current 'qq_bot_manager.exe'
    foreach ($ownedProcess in (Get-Process -Name 'qq_bot_manager' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $testExe })) {
      if (-not $ownedProcess.WaitForExit(5000)) { Stop-Process -Id $ownedProcess.Id }
    }
    $uninstaller = [IO.Path]::GetFullPath((Join-Path $current 'unins000.exe'))
    if (-not $uninstaller.StartsWith($fixture+'\',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'Refusing unexpected test uninstaller path.' }
    $cleanup = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG="'+(Join-Path $cache 'uninstall.log')+'"')) -WindowStyle Hidden -PassThru
    $cleanup.WaitForExit()
    if ($cleanup.ExitCode -ne 0 -or (Test-Path -LiteralPath $testRegistry)) { throw ('Test-only uninstall failed; inspect fixture ' + $fixture) }
    if ((Get-Content -LiteralPath (Join-Path $current 'keep-me.txt') -Raw) -ne 'preserve unrelated fixture') { throw 'Uninstaller removed unrelated fixture data.' }
    Write-Output 'PASS EXE: removed only test registration/program files; unrelated fixture data retained.'
  }
}
}
exit 0
