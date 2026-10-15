# Read-only validation of task-owned synthetic installations. Never launches QQ.
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$helper = Join-Path $workspace 'assets\updater\windows-update.ps1'
$fixture = Join-Path $workspace ('build\updater-validation-' + [Guid]::NewGuid().ToString('N'))
$install = Join-Path $fixture 'current'
$null = New-Item -ItemType Directory -Path (Join-Path $install 'data') -Force
[IO.File]::WriteAllText((Join-Path $install 'qq_bot_manager.exe'),'synthetic-not-executable')
[IO.File]::WriteAllText((Join-Path $install 'data\app.so'),'preserve-fixture')
$before = (Get-FileHash -LiteralPath (Join-Path $install 'data\app.so') -Algorithm SHA256).Hash
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$cases = @('valid','bad-hash','traversal','duplicate','symlink')
foreach ($caseName in $cases) {
  $cache = Join-Path $fixture $caseName
  $null = New-Item -ItemType Directory -Path $cache
  $package = Join-Path $cache 'package.zip'
  $archive = [IO.Compression.ZipFile]::Open($package,[IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($name in @('qq_bot_manager.exe','flutter_windows.dll','data/app.so')) {
      $entry = $archive.CreateEntry($name); $writer = [IO.StreamWriter]::new($entry.Open()); $writer.Write('test fixture'); $writer.Dispose()
    }
    if ($caseName -eq 'traversal') { $null = $archive.CreateEntry('../escape.txt') }
    if ($caseName -eq 'duplicate') { $null = $archive.CreateEntry('QQ_BOT_MANAGER.EXE') }
    if ($caseName -eq 'symlink') { $entry = $archive.CreateEntry('unsafe-link'); $entry.ExternalAttributes = -1610612736 }
  } finally { $archive.Dispose() }
  $hash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($caseName -eq 'bad-hash') { $hash = '0' * 64 }
  $ready = Join-Path $cache 'ready.json'; $requestPath = Join-Path $cache 'request.json'
  $request = @{schema=1;pid=0;executable=(Join-Path $install 'qq_bot_manager.exe');installDir=$install;package=$package;sha256=$hash;format='zip';cacheDir=$cache;readyFile=$ready}
  [IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
  & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -RequestPath $requestPath -ValidateOnly
  if (-not (Test-Path -LiteralPath $ready)) { throw ('No validation response: '+$caseName) }
  $response = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
  if ($response.ready -ne ($caseName -eq 'valid')) { throw ('Unexpected validation result: '+$caseName) }
  if ((Get-FileHash -LiteralPath (Join-Path $install 'data\app.so') -Algorithm SHA256).Hash -ne $before) { throw 'Validation changed the installation.' }
  Write-Output ('PASS '+$caseName)
}
if (Test-Path -LiteralPath (Join-Path $fixture 'escape.txt')) { throw 'ZIP traversal escaped its staging directory.' }
Write-Output ('Updater validation: 5 cases passed; fixture='+$fixture)
exit 0
