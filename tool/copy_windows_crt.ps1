# App-local release CRT, from the same Visual Studio installation selected by CMake.
param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$target = [IO.Path]::GetFullPath($Destination)
$buildRoot = Join-Path $workspace 'build'
if (-not $target.StartsWith($buildRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $target -PathType Container)) { throw 'CRT staging must be an existing task build directory.' }
$cache = Get-Content -LiteralPath (Join-Path $workspace 'build\windows\x64\CMakeCache.txt')
$instanceLine = $cache | Where-Object { $_ -match '^CMAKE_GENERATOR_INSTANCE:INTERNAL=' } | Select-Object -First 1
if (-not $instanceLine) { throw 'Visual Studio instance not recorded in CMake cache.' }
$instance = $instanceLine.Substring($instanceLine.IndexOf('=')+1)
$redist = Join-Path $instance 'VC\Redist\MSVC'
$runtime = $null
foreach ($version in (Get-ChildItem -LiteralPath $redist -Directory -Force | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)) {
  $x64 = Join-Path $version.FullName 'x64'
  if (Test-Path -LiteralPath $x64) {
    $runtime = Get-ChildItem -LiteralPath $x64 -Directory -Force -Filter 'Microsoft.VC*.CRT' | Select-Object -First 1
    if ($runtime) { break }
  }
}
if (-not $runtime) { throw 'Visual Studio release x64 CRT missing. Install its C++ Redistributable component; never use debug DLLs.' }
foreach ($required in @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')) {
  if (-not (Test-Path -LiteralPath (Join-Path $runtime.FullName $required) -PathType Leaf)) { throw ('Required release CRT file missing: '+$required) }
}
foreach ($file in (Get-ChildItem -LiteralPath $runtime.FullName -File -Filter '*.dll')) {
  $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw ('Microsoft CRT signature verification failed: '+$file.Name) }
  Copy-Item -LiteralPath $file.FullName -Destination $target
}
Write-Output ('Release x64 CRT staged: ' + $runtime.FullName)
