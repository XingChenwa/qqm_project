param([string]$Root = 'E:\QQBotManager\rvc-cover')
$ErrorActionPreference = 'Stop'
$coverRoot = [IO.Path]::GetFullPath($Root)
$coverPython = Join-Path $coverRoot 'env\Scripts\python.exe'
$coverScript = Join-Path $coverRoot 'service\service.py'
$coverConfig = Get-Content -LiteralPath (Join-Path $coverRoot 'config.json') -Raw | ConvertFrom-Json
foreach ($coverFile in @($coverPython,$coverScript)) {
  if (-not (Test-Path -LiteralPath $coverFile -PathType Leaf)) { throw ('缺少安装文件：'+$coverFile) }
}
try {
  $coverHealth = Invoke-RestMethod -Uri 'http://127.0.0.1:23339/api/health' -TimeoutSec 3
  if ($coverHealth.instanceId -eq $coverConfig.instanceId) {
    Write-Output '翻唱服务已在运行：http://127.0.0.1:23339/'
    exit 0
  }
  throw '端口23339已被其他实例占用；不会停止其他服务。'
} catch {
  if ($_.Exception.Message -like '*已被其他实例占用*') { throw }
}
$coverArguments = '"{0}" --root "{1}" --port 23339' -f $coverScript,$coverRoot
$coverProcess = Start-Process -FilePath $coverPython -ArgumentList $coverArguments -WorkingDirectory $coverRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $coverRoot 'logs\service.stdout.log') -RedirectStandardError (Join-Path $coverRoot 'logs\service.stderr.log')
$coverPidInfo = @{pid=$coverProcess.Id;python=$coverPython;script=$coverScript;instanceId=$coverConfig.instanceId}
[IO.File]::WriteAllText((Join-Path $coverRoot 'service.pid.json'),($coverPidInfo | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
for ($coverAttempt=0; $coverAttempt -lt 30; $coverAttempt++) {
  Start-Sleep -Milliseconds 400
  if ($coverProcess.HasExited) { throw '翻唱服务启动失败，请查看 logs\service.stderr.log。' }
  try {
    $coverHealth = Invoke-RestMethod -Uri 'http://127.0.0.1:23339/api/health' -TimeoutSec 2
    if ($coverHealth.instanceId -eq $coverConfig.instanceId) {
      Write-Output '翻唱服务已启动：http://127.0.0.1:23339/'
      Write-Output $coverHealth.message
      exit 0
    }
  } catch { }
}
throw '服务尚未就绪，请查看 logs\service.stderr.log；没有重复启动第二个实例。'
