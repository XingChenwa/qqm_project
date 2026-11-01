param([string]$Root = 'E:\QQBotManager\rvc-cover', [switch]$Start)
$ErrorActionPreference = 'Stop'
$coverRoot = [IO.Path]::GetFullPath($Root)
$coverSource = [IO.Path]::GetFullPath($PSScriptRoot)
$coverService = Join-Path $coverRoot 'service'
$coverOldSkill = Join-Path $coverRoot 'skill.json'
$coverOldSkillHash = if(Test-Path -LiteralPath $coverOldSkill){(Get-FileHash -LiteralPath $coverOldSkill -Algorithm SHA256).Hash}else{''}
foreach($coverFolder in @($coverRoot,$coverService,(Join-Path $coverService 'web'),(Join-Path $coverRoot 'logs'),(Join-Path $coverRoot 'models'),(Join-Path $coverRoot 'songs'),(Join-Path $coverRoot 'outputs'),(Join-Path $coverRoot 'jobs'),(Join-Path $coverRoot 'tmp'))){$null=New-Item -ItemType Directory -Path $coverFolder -Force}
foreach($coverName in @('service.py','pipeline.py','music.py','check_environment.py','test_service.py','constraints.txt','web\index.html')) {
  $coverInput=Join-Path $coverSource $coverName
  $coverOutput=Join-Path $coverService $coverName
  Copy-Item -LiteralPath $coverInput -Destination $coverOutput -Force
}
foreach($coverName in @('Start-Service.ps1','Stop-Service.ps1','skill.json','README.md')) {
  $coverInput=Join-Path $coverSource $coverName
  $coverOutput=Join-Path $coverRoot $coverName
  if($coverName.EndsWith('.ps1')) {
    # Windows PowerShell 5 reads non-BOM scripts as the local ANSI code page.
    [IO.File]::WriteAllText($coverOutput,[IO.File]::ReadAllText($coverInput,[Text.Encoding]::UTF8),[Text.UTF8Encoding]::new($true))
  } else {
    Copy-Item -LiteralPath $coverInput -Destination $coverOutput -Force
  }
}
$coverConfigFile = Join-Path $coverRoot 'config.json'
if(-not (Test-Path -LiteralPath $coverConfigFile)) {
  $coverFfmpeg = (Get-Command ffmpeg.exe -ErrorAction Stop).Source
  $coverConfig = @{schema=1;instanceId=[Guid]::NewGuid().ToString('N');ffmpeg=$coverFfmpeg}
  [IO.File]::WriteAllText($coverConfigFile,($coverConfig | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
}
$coverBase = Join-Path $coverRoot 'env\Lib\site-packages\rvc_python\base_model'
$null=New-Item -ItemType Directory -Path $coverBase -Force
$coverHashes=@{'hubert_base.pt'='f54b40fd2802423a5643779c4861af1e9ee9c1564dc9d32f54f20b5ffba7db96';'rmvpe.pt'='6d62215f4306e3ca278246188607209f09af3dc77ed4232efdd069798c4ec193'}
foreach($coverName in $coverHashes.Keys) {
  $coverInput=Join-Path (Join-Path $coverRoot 'base-models') $coverName
  if((Get-FileHash -LiteralPath $coverInput -Algorithm SHA256).Hash.ToLowerInvariant() -ne $coverHashes[$coverName]){throw ('基础模型校验失败：'+$coverName)}
  Copy-Item -LiteralPath $coverInput -Destination (Join-Path $coverBase $coverName) -Force
}
$coverQueue = Join-Path $env:LOCALAPPDATA 'QQBotManager\agent-imports'
$null=New-Item -ItemType Directory -Path $coverQueue -Force
$coverQueueFile = Join-Path $coverQueue 'local-rvc-cover.json'
if(-not (Test-Path -LiteralPath $coverQueueFile) -or
    ($coverOldSkillHash -and (Get-FileHash -LiteralPath $coverQueueFile -Algorithm SHA256).Hash -eq $coverOldSkillHash)) {
  Copy-Item -LiteralPath (Join-Path $coverRoot 'skill.json') -Destination $coverQueueFile
}
$coverStarter = '@echo off'+"`r`n"+'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Service.ps1" -Root "%~dp0"'+"`r`n"+'pause'+"`r`n"
[IO.File]::WriteAllText((Join-Path $coverRoot '启动翻唱服务.cmd'),$coverStarter,[Text.Encoding]::ASCII)
Write-Output '已部署本地翻唱服务和待导入Skill；音色 / 歌曲 / 已有应用设置保持原样。'
if($Start) { & (Join-Path $coverRoot 'Start-Service.ps1') -Root $coverRoot }
