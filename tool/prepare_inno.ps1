# Prepare a pinned, verified compiler without global installation, shortcuts or file associations.
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$toolsDirectory = Join-Path $workspace 'build\tools'
$compiler = Join-Path $toolsDirectory 'inno-6.7.3'
$setup = Join-Path $toolsDirectory 'innosetup-6.7.3.exe'
$compilerHash = '9C73C3BAE7ED48D44112A0F48E66742C00090BDB5BEF71D9D3C056C66E97B732'
$translationHash = '7D544B9BB1D142CFA11F2E5D3CC8ABE2E55F8E066C5124E3772675AA236E1278'
function Verify-Publisher([string]$File) {
  $signature = Get-AuthenticodeSignature -LiteralPath $File
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Pyrsys B\.V\.') { throw 'Inno Setup publisher verification failed; refusing to execute downloaded code.' }
}
$null = New-Item -ItemType Directory -Path $toolsDirectory -Force
if (-not (Test-Path -LiteralPath (Join-Path $compiler 'ISCC.exe'))) {
  if (-not (Test-Path -LiteralPath $setup)) { Invoke-WebRequest -Uri 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe' -OutFile $setup }
  if ((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash -ne $compilerHash) { throw 'Pinned Inno Setup SHA-256 does not match.' }
  Verify-Publisher $setup
  # PORTABLE=1 is supported by Inno Setup's own isportable.iss: no uninstall registration/associations/icons.
  $arguments = @('/PORTABLE=1','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/CURRENTUSER',('/DIR="' + $compiler + '"'),('/LOG="' + (Join-Path $toolsDirectory 'inno-portable-install.log') + '"'))
  $process = Start-Process -FilePath $setup -ArgumentList $arguments -WindowStyle Hidden -PassThru
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) { throw ('Portable Inno Setup preparation failed: ' + $process.ExitCode) }
}
Verify-Publisher (Join-Path $compiler 'ISCC.exe')
$translation = Join-Path $compiler 'Languages\ChineseSimplified.isl'
if (-not (Test-Path -LiteralPath $translation)) {
  Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/jrsoftware/issrc/is-6_7_3/Files/Languages/Unofficial/ChineseSimplified.isl' -OutFile $translation
}
if ((Get-FileHash -LiteralPath $translation -Algorithm SHA256).Hash -ne $translationHash) { throw 'Pinned Simplified Chinese translation SHA-256 does not match.' }
Write-Output (Join-Path $compiler 'ISCC.exe')
