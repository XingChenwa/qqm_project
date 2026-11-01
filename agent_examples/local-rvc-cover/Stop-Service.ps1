param([string]$Root = 'E:\QQBotManager\rvc-cover')
$ErrorActionPreference = 'Stop'
$coverRoot = [IO.Path]::GetFullPath($Root)
$coverPidFile = Join-Path $coverRoot 'service.pid.json'
if (-not (Test-Path -LiteralPath $coverPidFile -PathType Leaf)) { Write-Output '没有本安装目录的服务记录。'; exit 0 }
$coverInfo = Get-Content -LiteralPath $coverPidFile -Raw | ConvertFrom-Json
$coverProcessId = [int]$coverInfo.pid
if ($coverProcessId -le 0) { throw '服务进程记录无效。' }
$coverProcess = Get-CimInstance Win32_Process -Filter ('ProcessId='+$coverProcessId) -ErrorAction SilentlyContinue
if (-not $coverProcess) { Write-Output '服务已停止。'; exit 0 }
if ($coverProcess.ExecutablePath -ne (Join-Path $coverRoot 'env\Scripts\python.exe') -or
    -not $coverProcess.CommandLine.Contains((Join-Path $coverRoot 'service\service.py')) -or
    -not $coverProcess.CommandLine.Contains($coverRoot)) {
  throw '进程与本安装目录不一致，拒绝停止其他进程。'
}
& (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $coverProcessId /T /F
$coverStopExit = $LASTEXITCODE
# A venv launcher can exit by itself while taskkill is stopping its children.
# Do not report a stopped service as a failure merely because that parent exited.
$coverRemaining = Get-CimInstance Win32_Process -Filter ('ProcessId='+$coverProcessId) -ErrorAction SilentlyContinue
if ($coverStopExit -ne 0 -and $coverRemaining -and $coverRemaining.CreationDate -eq $coverProcess.CreationDate) { throw '服务未能停止，请检查进程状态。' }
Write-Output '本地翻唱服务及其处理子进程已停止。'
