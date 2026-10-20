class AppConstants {
  static const String projectUrl = 'https://github.com/XingChenwa/qqm_project';
  static const String appVersion = '1.3.9';
  static const int appBuild = 29;
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
