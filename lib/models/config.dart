import 'package:hive/hive.dart';
import '../utils/constants.dart';

class BotConfig {
  static const int oiapiNicknameDefaultVersion = 1;

  /// 旧版默认关闭；首次升级改为开启，之后保留用户主动保存的选择。
  static bool needsOiapiNicknameDefaultMigration(Map<String, dynamic> map) =>
      (map['oiapiNicknameDefaultVersion'] as int? ?? 0) <
      oiapiNicknameDefaultVersion;

  String appId;
  String clientSecret;
  String accessToken;
  int tokenExpiresAt; // Unix timestamp in seconds
  String apiBaseUrl;
  bool useSandbox;
  bool autoReconnect;
  bool receiveAllGroupMessages;
  bool autoReplyToAllGroupMessages;
  int reconnectInterval;
  List<String> monitoredGroups;
  List<String> monitoredFriends;
  bool enableAutoReply;
  String defaultAutoReply;
  Map<String, String> keywordReplies;
  bool enableScheduledTasks;
  bool enableLogging;
  bool enableOiapiNickname;
  bool closeToTray;
  bool skipCloseConfirmation;

  // Markdown template
  String markdownTemplateId;
  List<Map<String, String>> markdownTemplateParams;

  BotConfig({
    this.appId = '',
    this.clientSecret = '',
    this.accessToken = '',
    this.tokenExpiresAt = 0,
    this.apiBaseUrl = AppConstants.qqBaseUrl,
    this.useSandbox = false,
    this.autoReconnect = true,
    this.receiveAllGroupMessages = true,
    this.autoReplyToAllGroupMessages = false,
    this.reconnectInterval = 5,
    List<String>? monitoredGroups,
    List<String>? monitoredFriends,
    this.enableAutoReply = false,
    this.defaultAutoReply = '',
    Map<String, String>? keywordReplies,
    this.enableScheduledTasks = false,
    this.enableLogging = true,
    this.enableOiapiNickname = true,
    this.closeToTray = false,
    this.skipCloseConfirmation = false,
    this.markdownTemplateId = '',
    List<Map<String, String>>? markdownTemplateParams,
  }) : monitoredGroups = monitoredGroups ?? [],
       monitoredFriends = monitoredFriends ?? [],
       keywordReplies = keywordReplies ?? {},
       markdownTemplateParams = markdownTemplateParams ?? [];

  bool get isTokenExpired =>
      accessToken.isEmpty ||
      tokenExpiresAt <= 0 ||
      DateTime.now().millisecondsSinceEpoch ~/ 1000 >= tokenExpiresAt - 60;

  String get resolvedApiBaseUrl => useSandbox
      ? AppConstants.qqSandboxUrl
      : AppConstants.normalizeApiBaseUrl(apiBaseUrl);

  Map<String, dynamic> toMap() => {
    'appId': appId,
    'clientSecret': clientSecret,
    'accessToken': accessToken,
    'tokenExpiresAt': tokenExpiresAt,
    'apiBaseUrl': apiBaseUrl,
    'useSandbox': useSandbox,
    'autoReconnect': autoReconnect,
    'receiveAllGroupMessages': receiveAllGroupMessages,
    'autoReplyToAllGroupMessages': autoReplyToAllGroupMessages,
    'reconnectInterval': reconnectInterval,
    'monitoredGroups': monitoredGroups,
    'monitoredFriends': monitoredFriends,
    'enableAutoReply': enableAutoReply,
    'defaultAutoReply': defaultAutoReply,
    'keywordReplies': keywordReplies,
    'enableScheduledTasks': enableScheduledTasks,
    'enableLogging': enableLogging,
    'enableOiapiNickname': enableOiapiNickname,
    'oiapiNicknameDefaultVersion': oiapiNicknameDefaultVersion,
    'closeToTray': closeToTray,
    'skipCloseConfirmation': skipCloseConfirmation,
    'markdownTemplateId': markdownTemplateId,
    'markdownTemplateParams': markdownTemplateParams,
  };

  factory BotConfig.fromMap(Map<String, dynamic> map) => BotConfig(
    appId: map['appId'] as String? ?? '',
    clientSecret: map['clientSecret'] as String? ?? '',
    accessToken: map['accessToken'] as String? ?? '',
    tokenExpiresAt: map['tokenExpiresAt'] as int? ?? 0,
    apiBaseUrl: AppConstants.normalizeApiBaseUrl(
      map['apiBaseUrl'] as String? ?? '',
    ),
    useSandbox: map['useSandbox'] as bool? ?? false,
    autoReconnect: map['autoReconnect'] as bool? ?? true,
    receiveAllGroupMessages: map['receiveAllGroupMessages'] as bool? ?? true,
    autoReplyToAllGroupMessages:
        map['autoReplyToAllGroupMessages'] as bool? ?? false,
    reconnectInterval: map['reconnectInterval'] as int? ?? 5,
    monitoredGroups: List<String>.from(map['monitoredGroups'] as List? ?? []),
    monitoredFriends: List<String>.from(map['monitoredFriends'] as List? ?? []),
    enableAutoReply: map['enableAutoReply'] as bool? ?? false,
    defaultAutoReply: map['defaultAutoReply'] as String? ?? '',
    keywordReplies: Map<String, String>.from(
      map['keywordReplies'] as Map? ?? {},
    ),
    enableScheduledTasks: map['enableScheduledTasks'] as bool? ?? false,
    enableLogging: map['enableLogging'] as bool? ?? true,
    enableOiapiNickname: needsOiapiNicknameDefaultMigration(map)
        ? true
        : map['enableOiapiNickname'] as bool? ?? true,
    closeToTray: map['closeToTray'] as bool? ?? false,
    skipCloseConfirmation: map['skipCloseConfirmation'] as bool? ?? false,
    markdownTemplateId: map['markdownTemplateId'] as String? ?? '',
    markdownTemplateParams:
        (map['markdownTemplateParams'] as List<dynamic>?)
            ?.map((e) => Map<String, String>.from(e as Map))
            .toList() ??
        [],
  );
}

class BotConfigAdapter extends TypeAdapter<BotConfig> {
  @override
  final int typeId = 4;

  @override
  BotConfig read(BinaryReader reader) {
    final map = Map<String, dynamic>.from(
      (reader.readMap()).map((k, v) => MapEntry(k.toString(), v)),
    );
    return BotConfig.fromMap(map);
  }

  @override
  void write(BinaryWriter writer, BotConfig obj) {
    writer.writeMap(obj.toMap());
  }
}
