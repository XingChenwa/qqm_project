# Package source and deployment instructions only; never include server state or secrets.
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $workspace ('build\management-deploy-' + [Guid]::NewGuid().ToString('N'))
$output = Join-Path $workspace 'dist\qqbotmanager-baota-mysql-v1.3.2-build13.zip'
if (Test-Path -LiteralPath $output) { throw 'Deployment ZIP already exists; preserve the existing artifact.' }
$paths = @('management/config.example.php','management/README.md','management/DEPLOY.txt','management/data/.gitignore','docs/update-and-edgeone.md','docs/windows-release.md','docs/mobile-build.md')
foreach ($directory in @('management/src','management/public','management/bin','management/deploy','management/database','management/tests')) {
  $paths += Get-ChildItem -LiteralPath (Join-Path $workspace $directory) -File -Recurse | ForEach-Object { $_.FullName.Substring($workspace.Length+1) }
}
foreach ($relative in $paths) {
  $source = [IO.Path]::GetFullPath((Join-Path $workspace $relative))
  if (-not $source.StartsWith($workspace+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected source path.' }
  # The ZIP is the Baota application root, not a second management/ directory.
  $portableRelative = $relative.Replace('\','/')
  $archiveRelative = if ($portableRelative.StartsWith('management/')) { $portableRelative.Substring('management/'.Length) } else { $portableRelative }
  $target = Join-Path $stage $archiveRelative
  $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
  Copy-Item -LiteralPath $source -Destination $target
}
# Keep documentation links correct after flattening the deployment layout.
$deployReadme = Join-Path $stage 'README.md'
$readmeText = [IO.File]::ReadAllText($deployReadme).Replace('(../docs/update-and-edgeone.md)', '(docs/update-and-edgeone.md)')
[IO.File]::WriteAllText($deployReadme, $readmeText, [Text.UTF8Encoding]::new($false))
$edgeoneDoc = Join-Path $stage 'docs/update-and-edgeone.md'
$edgeoneText = [IO.File]::ReadAllText($edgeoneDoc).Replace('(../management/README.md)', '(../README.md)')
[IO.File]::WriteAllText($edgeoneDoc, $edgeoneText, [Text.UTF8Encoding]::new($false))
$null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($output)) -Force
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $output
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($output)
try {
  foreach ($entry in $archive.Entries) {
    $name = $entry.FullName.Replace('\','/')
    if ($name -match '(?i)(^|/)(config\.(?:json|php)|[^/]+\.sqlite(?:-wal|-shm)?|[^/]+\.jks|[^/]+\.keystore|[^/]+\.p12|[^/]+\.pfx|[^/]+\.apk|[^/]+\.ipa)$' -or ($name.StartsWith('data/') -and $name -ne 'data/.gitignore')) { throw ('Private/runtime data in deployment ZIP: '+$name) }
    if ($name -match '(?i)\.(sql|sql\.gz|dump)$' -and $name -ne 'database/schema.sql') { throw ('Database dump in deployment ZIP: '+$name) }
  }
  $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\','/') })
  foreach ($required in @('config.example.php','src/Configuration.php','src/Core.php','public/index.php','bin/manage.php','database/schema.sql','DEPLOY.txt','docs/update-and-edgeone.md')) {
    if ($names -notcontains $required) { throw ('Required deployment file missing: '+$required) }
  }
  Write-Output ('Deployment source entries='+$archive.Entries.Count)
} finally { $archive.Dispose() }
Get-FileHash -LiteralPath $output -Algorithm SHA256
Write-Output $output
