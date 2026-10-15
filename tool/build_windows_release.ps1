param(
  [Parameter(Mandatory=$true)][string]$UpdatePublicKey,
  [string]$UpdateBaseUrl = 'https://botmanager.uuze.cn',
  [string]$Flutter = 'flutter',
  [switch]$Installer,
  [string]$Iscc = 'ISCC.exe'
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$key = [Convert]::FromBase64String($UpdatePublicKey)
if ($key.Length -ne 32) { throw 'UPDATE_PUBLIC_KEY must be a 32-byte Ed25519 public key in base64, NOT the private key.' }
$uri = [Uri]$UpdateBaseUrl
if ($uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) { throw 'UpdateBaseUrl must be an HTTPS origin.' }
if ($Installer -and -not (Get-Command $Iscc -ErrorAction SilentlyContinue)) { throw 'Install Inno Setup 6.5+ or supply -Iscc with its compiler path.' }
if ($Installer) {
  $compilerDirectory = Split-Path -Parent (Get-Command $Iscc).Source
  if (-not (Test-Path -LiteralPath (Join-Path $compilerDirectory 'Languages\ChineseSimplified.isl'))) { throw 'Simplified Chinese language file missing. Run tool/prepare_inno.ps1 and pass its ISCC path.' }
}
$versionText = Get-Content -LiteralPath (Join-Path $workspace 'pubspec.yaml') -Raw
if ($versionText -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw 'Cannot read the release version.' }
$version = $Matches[1]; $buildNumber = $Matches[2]
$dist = Join-Path $workspace 'dist'
$output = Join-Path $dist ("qqbotmanager-windows-v$version-build$buildNumber.zip")
$setup = Join-Path $dist ("qqbotmanager-windows-v$version-build$buildNumber-setup.exe")
$buildInfo = Join-Path $dist ("qqbotmanager-windows-v$version-build$buildNumber-build-info.json")
if ((Test-Path -LiteralPath $output) -or (Test-Path -LiteralPath $buildInfo) -or ($Installer -and (Test-Path -LiteralPath $setup))) { throw 'Output already exists; choose a new build number instead of overwriting a release.' }
Push-Location $workspace
try {
  # Explicit production entrypoint: never accidentally package the native smoke-test app.
  & $Flutter build windows --release --target=lib/main.dart "--dart-define=UPDATE_BASE_URL=$UpdateBaseUrl" "--dart-define=UPDATE_PUBLIC_KEY=$UpdatePublicKey"
  if ($LASTEXITCODE -ne 0) { throw 'Flutter build failed.' }
  $source = [IO.Path]::GetFullPath((Join-Path $workspace 'build\windows\x64\runner\Release'))
  $stage = Join-Path $workspace ('build\windows-package-' + [Guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Path $stage
  $files = @(Get-Content -LiteralPath (Join-Path $workspace 'build\windows\x64\install_manifest.txt'))
  $files += @('qq_bot_manager.exe','WebView2Loader.dll') | ForEach-Object { Join-Path $source $_ }
  # Current Flutter uses the installed NativeAssetsManifest.json. Older SDKs may
  # also emit this root manifest; it is not present in every clean build.
  $optionalManifest = Join-Path $source 'native_assets.json'
  if (Test-Path -LiteralPath $optionalManifest -PathType Leaf) { $files += $optionalManifest }
  foreach ($file in ($files | Select-Object -Unique)) {
    $resolved = [IO.Path]::GetFullPath($file)
    if (-not $resolved.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Runtime source outside Release.' }
    $target = Join-Path $stage $resolved.Substring($source.Length+1)
    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
    Copy-Item -LiteralPath $resolved -Destination $target
  }
  foreach ($required in @('qq_bot_manager.exe','flutter_windows.dll','data\app.so')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $required) -PathType Leaf)) { throw ('Missing runtime file: '+$required) }
  }
  & (Join-Path $PSScriptRoot 'copy_windows_crt.ps1') -Destination $stage
  $licenseDirectory = Join-Path $stage 'licenses'
  $null = New-Item -ItemType Directory -Path $licenseDirectory
  Copy-Item -LiteralPath (Join-Path $workspace 'scripts\licenses\inno-chinese-MIT.txt') -Destination $licenseDirectory
  $metadata = [ordered]@{schema=1;package_id='cn.uuze.botmanager';platform='windows';arch='x64';version=$version;build=[int]$buildNumber;entrypoint='lib/main.dart';update_server=$uri.GetLeftPart([UriPartial]::Authority);update_public_key=$UpdatePublicKey;crt_version=(Get-Item -LiteralPath (Join-Path $stage 'msvcp140.dll')).VersionInfo.FileVersion}
  [IO.File]::WriteAllText((Join-Path $stage 'release-info.json'),($metadata | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
  $null = New-Item -ItemType Directory -Path $dist -Force
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $output
  Get-FileHash -LiteralPath $output -Algorithm SHA256
  if ($Installer) {
    $icon = Join-Path $workspace 'windows\runner\resources\app_icon.ico'
    & $Iscc "/DAppFiles=$stage" "/DAppOutput=$dist" "/DAppVersion=$version" "/DBuildNumber=$buildNumber" "/DAppIcon=$icon" (Join-Path $workspace 'scripts\windows-installer.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed; ZIP remains available.' }
    Get-FileHash -LiteralPath $setup -Algorithm SHA256
  }
  $metadata['artifacts'] = @(@{name=[IO.Path]::GetFileName($output);format='zip';size=(Get-Item -LiteralPath $output).Length;sha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()})
  if ($Installer) { $metadata['artifacts'] += @{name=[IO.Path]::GetFileName($setup);format='exe';size=(Get-Item -LiteralPath $setup).Length;sha256=(Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()} }
  [IO.File]::WriteAllText($buildInfo,($metadata | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
  Write-Output $buildInfo
  Write-Output 'Packages built. Upload as drafts and verify before publishing. This command never starts the QQ application.'
} finally { Pop-Location }
