; Inno Setup 6.5+ with the contributed Simplified Chinese translation.
; tool/prepare_inno.ps1 prepares a verified, project-local portable compiler.
#ifndef AppFiles
  #error AppFiles must be the fresh staging directory supplied by the build helper.
#endif
#ifndef AppOutput
  #error AppOutput is required.
#endif
#ifndef AppVersion
  #error AppVersion is required.
#endif
#ifndef BuildNumber
  #error BuildNumber is required.
#endif
#ifndef AppIcon
  #error AppIcon is required.
#endif
#ifdef QaIdentity
  ; Test-only registry identity: never register tests as the user's real application.
  #define ProductIdentity "cn.uuze.botmanager.qa-" + QaIdentity
  #define ProductTitle "QQM 安装自测 " + QaIdentity
#else
  #define ProductIdentity "cn.uuze.botmanager"
  #define ProductTitle "QQ机器人管理器"
#endif

[Setup]
AppId={#ProductIdentity}
AppName={#ProductTitle}
AppVersion={#AppVersion}
AppPublisher=QQ机器人管理器
AppPublisherURL=https://botmanager.uuze.cn
AppSupportURL=https://botmanager.uuze.cn
AppUpdatesURL=https://botmanager.uuze.cn
DefaultDirName={localappdata}\Programs\QQBotManager
DisableProgramGroupPage=yes
DisableWelcomePage=no
DisableDirPage=no
UsePreviousAppDir=yes
UsePreviousTasks=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#AppOutput}
OutputBaseFilename=qqbotmanager-windows-v{#AppVersion}-build{#BuildNumber}-setup
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\qq_bot_manager.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
SetupLogging=yes
VersionInfoVersion={#AppVersion}.{#BuildNumber}

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; Flags: unchecked

[Files]
Source: "{#AppFiles}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

#ifndef QaIdentity
[Icons]
Name: "{autoprograms}\QQ机器人管理器"; Filename: "{app}\qq_bot_manager.exe"
Name: "{autodesktop}\QQ机器人管理器"; Filename: "{app}\qq_bot_manager.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\qq_bot_manager.exe"; Description: "启动 QQ机器人管理器"; Flags: nowait postinstall skipifsilent
#endif

; No UninstallDelete section: never delete bot settings, chat databases or user-created files.
