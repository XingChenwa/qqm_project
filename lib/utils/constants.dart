class AppConstants {
  static const String projectUrl = 'https://github.com/XingChenwa/qqm_project';
  static const String communityGroupName = '嘿壳群聊 QQ机器人管理器';
  static const String communityGroupUrl =
      'https://qun.qq.com/universal-share/share?ac=1&authKey=k9Si0Ky6xRALe8bTNU%2Bk7BAexdY2QdV4Dx917AWx9dHLHUcAHZ87ZUSoKyD8h2i4'
      '&busi_data=eyJncm91cENvZGUiOiIxMTM0MzE4NzUyIiwidG9rZW4iOiJPT2g2aEZ0TEE5cmU5c2t4Q0pObDg3YmhoZUNEVlJTVm1SRklQQlR2b2pna1BUWmhnUXlZbHR4TjAvOGp3b2QxIiwidWluIjoiMjM3NzEzMDc4MyJ9'
      '&data=g7BSK-QGO_OwDx56JOAxFXo9nBWbfK6MgZ3tYy4tlpGDJ8MWOS9FNOtxTFlGGZyyKdL1RnB8oV4RUxDmB5dRiw&svctype=4&tempid=h5_group_info';
  static const String appVersion = '1.4.1';
  static const int appBuild = 44;
  // CI supplies the GitHub Pre-release flag; a source run follows its version.
  static const String releaseChannel = String.fromEnvironment('UPDATE_CHANNEL');
  // QQ Bot API endpoints
  static const String qqBaseUrl = 'https://api.bot.qq.com';
  static const String qqTokenUrl = '$qqBaseUrl/app/getAppAccessToken';
  static const String qqSandboxUrl = 'https://sandbox.api.sgroup.qq.com';

  // QQ Bot WebSocket
  static const String qqWsUrl = 'wss://api.bot.qq.com/websocket/';

  static String normalizeApiBaseUrl(String value) {
    final url = value.trim().replaceFirst(RegExp(r'/+$'), '');
    return url.isEmpty || url == 'https://api.sgroup.qq.com' ? qqBaseUrl : url;
  }

  // Emoji API endpoints
  static const List<String> emojiApis = [
    'https://i.uuze.cn/api/mingfengouo',
    'https://i.uuze.cn/api/nachoneko3',
    'https://i.uuze.cn/api/majosaiban',
    'https://i.uuze.cn/api/czemojibot',
    'https://i.uuze.cn/api/hu_goal_capoo',
    'https://i.uuze.cn/api/catearniang',
    'https://i.uuze.cn/api/zimaomao',
  ];

  // Plugin directory
  static const String pluginDirName = 'plugins';

  // Storage keys
  static const String botConfigKey = 'bot_config';
  static const String themeKey = 'theme_dark';
  static const String messagesBox = 'messages';
  static const String sessionsBox = 'chat_sessions';
  static const String emojisBox = 'custom_emojis';
  static const String pluginsBox = 'plugin_configs';

  // QQ Message types
  static const int msgTypeText = 0;
  static const int msgTypeMarkdown = 2;
  static const int msgTypeArk = 3;
  static const int msgTypeEmbed = 4;
  static const int msgTypeImage = 7;

  // Window default size
  static const double defaultWidth = 1280;
  static const double defaultHeight = 800;
  static const double minSidebarWidth = 220;
  static const double maxSidebarWidth = 350;
  static const double rightPanelWidth = 300;
  static const double inputBarHeight = 160;
}
