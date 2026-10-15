param([Parameter(Mandatory=$true)][string]$RequestPath, [switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
$request = $null; $cacheRoot = $null; $mutex = $null; $locked = $false; $parentExited = $false
$backedUp = [Collections.Generic.List[string]]::new()
$newFiles = [Collections.Generic.List[string]]::new()
function Canonical([string]$Value) { [IO.Path]::GetFullPath($Value).TrimEnd('\') }
function Require-Child([string]$Value, [string]$Root) {
  $resolved = Canonical $Value
  if (-not $resolved.StartsWith((Canonical $Root) + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Path is outside the allowed directory.' }
  return $resolved
}
function No-Reparse([string]$Value) {
  $item = $Value
  while ($item) {
    if (Test-Path -LiteralPath $item) {
      if (((Get-Item -Force -LiteralPath $item).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Junctions and symbolic links are not allowed for updating.' }
    }
    $next = [IO.Path]::GetDirectoryName($item)
    if ($next -eq $item) { break }; $item = $next
  }
}
function Write-Ready([bool]$Ready, [string]$Message) {
  if ($request -and $cacheRoot) {
    $readyPath = Require-Child $request.readyFile $cacheRoot
    $temporary = $readyPath + '.tmp'
    @{ready=$Ready; error=$Message} | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $readyPath -Force
  }
}
try {
  $requestPathResolved = Canonical $RequestPath
  $cacheRoot = Canonical ([IO.Path]::GetDirectoryName($requestPathResolved))
  No-Reparse $cacheRoot
  $request = Get-Content -LiteralPath $requestPathResolved -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($request.schema -ne 1 -or (Canonical $request.cacheDir) -ne $cacheRoot) { throw 'Invalid update request.' }
  $package = Require-Child $request.package $cacheRoot
  $installRoot = Canonical $request.installDir
  No-Reparse $installRoot
  if ($installRoot -eq [IO.Path]::GetPathRoot($installRoot).TrimEnd('\')) { throw 'Cannot update a drive root.' }
  foreach ($special in @($env:USERPROFILE,[Environment]::GetFolderPath('Desktop'),[Environment]::GetFolderPath('MyDocuments'),[Environment]::GetFolderPath('MyPictures'))) {
    if ($special -and $installRoot -eq (Canonical $special)) { throw 'Please extract the app into its own folder before updating.' }
  }
  $executable = Require-Child $request.executable $installRoot
  if ([IO.Path]::GetFileName($executable) -ne 'qq_bot_manager.exe' -or -not (Test-Path -LiteralPath $executable) -or -not (Test-Path -LiteralPath (Join-Path $installRoot 'data\app.so'))) { throw 'The running application directory is not valid.' }
  if ($request.sha256 -notmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash -ne $request.sha256) { throw 'The update package SHA-256 does not match.' }
  if ($request.format -notin @('zip','exe')) { throw 'Unsupported update package format.' }
  $hasher = [Security.Cryptography.SHA256]::Create()
  $lockKey = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($installRoot.ToLowerInvariant())))).Replace('-','').Substring(0,24)
  $hasher.Dispose()
  $mutex = [Threading.Mutex]::new($false, ('Local\QQMUpdater-' + $lockKey))
  $locked = $mutex.WaitOne(0)
  if (-not $locked) { throw 'Another updater is already preparing this application.' }
  $stage = Require-Child (Join-Path $cacheRoot ('stage-' + [Guid]::NewGuid().ToString('N'))) $cacheRoot
  $backup = Require-Child (Join-Path $cacheRoot ('backup-' + [Guid]::NewGuid().ToString('N'))) $cacheRoot
  $files = [Collections.Generic.List[string]]::new()
  if ($request.format -eq 'zip') {
    $null = New-Item -ItemType Directory -Path $stage
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($package)
    try {
      if ($archive.Entries.Count -gt 20000) { throw 'Too many files in the update.' }
      $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
      [long]$expanded = 0
      foreach ($entry in $archive.Entries) {
        $relative = $entry.FullName.Replace('/','\')
        if (-not $relative -or $relative.StartsWith('\') -or $relative.Contains(':') -or $relative -match '(^|\\)\.\.?($|\\)|[\x00-\x1f]') { throw 'Unsafe ZIP path.' }
        foreach ($segment in $relative.TrimEnd('\').Split('\')) {
          if (-not $segment -or $segment -match '[. ]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw 'Unsafe Windows filename.' }
        }
        if (-not $seen.Add($relative)) { throw 'Duplicate ZIP path.' }
        if ((($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960) { throw 'Symbolic links in the update are forbidden.' }
        $expanded += $entry.Length
        if ($expanded -gt 2147483648) { throw 'Expanded ZIP is too large.' }
        $destination = Require-Child (Join-Path $stage $relative) $stage
        if ($relative.EndsWith('\')) { $null = New-Item -ItemType Directory -Path $destination -Force; continue }
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination)
        $files.Add($relative)
      }
      foreach ($required in @('qq_bot_manager.exe','flutter_windows.dll','data\app.so')) {
        if (-not $seen.Contains($required)) { throw ('Update is missing ' + $required) }
      }
    } finally { $archive.Dispose() }
    $probe = Require-Child (Join-Path $installRoot ('.qqm-update-probe-' + [Guid]::NewGuid().ToString('N'))) $installRoot
    $stream = [IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write); $stream.Dispose()
    Remove-Item -LiteralPath $probe
  }
  if ($ValidateOnly) { Write-Ready $true ''; exit 0 }
  if ([int]$request.pid -le 0) { throw 'Invalid parent process.' }
  $parent = [Diagnostics.Process]::GetProcessById([int]$request.pid)
  if ((Canonical $parent.MainModule.FileName) -ne $executable) { throw 'Parent process executable does not match.' }
  Write-Ready $true ''
  if (-not $parent.WaitForExit(120000)) { throw 'The application did not exit; no installation files were changed.' }
  $parentExited = $true
  if ($request.format -eq 'exe') {
    # Only vendor-published Inno Setup installers are supported by this path.
    $directoryArgument = '/DIR="' + $installRoot + '"'
    $logArgument = '/LOG="' + (Join-Path $cacheRoot 'installer.log') + '"'
    $installer = Start-Process -FilePath $package -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/NOCLOSEAPPLICATIONS','/NORESTARTAPPLICATIONS','/LANG=chinesesimplified', $logArgument, $directoryArgument) -WindowStyle Hidden -PassThru
    $installer.WaitForExit()
    if ($installer.ExitCode -ne 0) { throw 'The installer did not finish successfully.' }
  } else {
    $null = New-Item -ItemType Directory -Path $backup
    foreach ($relative in $files) {
      $destination = Require-Child (Join-Path $installRoot $relative) $installRoot
      No-Reparse $destination
      if (Test-Path -LiteralPath $destination) {
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw 'A destination file is a directory.' }
        $saved = Require-Child (Join-Path $backup $relative) $backup
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($saved)) -Force
        Copy-Item -LiteralPath $destination -Destination $saved
        $backedUp.Add($relative)
      } else { $newFiles.Add($relative) }
      $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force
      Copy-Item -LiteralPath (Require-Child (Join-Path $stage $relative) $stage) -Destination $destination -Force
    }
  }
  @{success=$true; backup=$backup; at=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $cacheRoot 'result.json') -Encoding UTF8
  Start-Process -FilePath $executable -WorkingDirectory $installRoot -WindowStyle Hidden
} catch {
  $message = $_.Exception.Message
  if ($parentExited -and $request.format -eq 'zip') {
    foreach ($relative in $backedUp) {
      try { Copy-Item -LiteralPath (Require-Child (Join-Path $backup $relative) $backup) -Destination (Require-Child (Join-Path $installRoot $relative) $installRoot) -Force } catch {}
    }
    foreach ($relative in $newFiles) {
      try { $target = Require-Child (Join-Path $installRoot $relative) $installRoot; if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target } } catch {}
    }
  }
  if ($cacheRoot -and $request) {
    try { @{success=$false; error=$message; backup=$backup} | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $cacheRoot 'result.json') -Encoding UTF8 } catch {}
    try { if (-not (Test-Path -LiteralPath (Require-Child $request.readyFile $cacheRoot))) { Write-Ready $false $message } } catch {}
  }
  if ($parentExited -and $executable -and (Test-Path -LiteralPath $executable)) {
    try { Start-Process -FilePath $executable -WorkingDirectory $installRoot -WindowStyle Hidden } catch {}
  }
  exit 1
} finally {
  if ($locked) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() }
}
