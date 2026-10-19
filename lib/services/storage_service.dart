import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/message.dart';
import '../models/config.dart';
import '../models/plugin.dart';

class StorageService {
  late Box<String> _messagesBox;
  late Box<String> _sessionsBox;
  late Box<String> _emojisBox;
  late Box<String> _pluginsBox;
  late Box<String> _pluginDataBox;
  late SharedPreferences _prefs;
  String? _chatAppId;
  Future<void> _configWrites = Future<void>.value();
  String get activeBotAppId => _chatAppId ?? getBotConfig().appId;
  void selectChatAccount(String appId) => _chatAppId = appId;

  Future<void> init({void Function(String)? report}) async {
    try {
      await _initialize(report);
    } on PlatformException catch (error, stack) {
      if (kIsWeb ||
          defaultTargetPlatform != TargetPlatform.android ||
          !{'channel-error', 'missing-plugin'}.contains(error.code)) {
        rethrow;
      }
      report?.call('恢复 Android 偏好设置通道（保留本地数据）');
      try {
        await const MethodChannel(
          'cn.uuze.botmanager/runtime',
        ).invokeMethod<bool>('repairPreferences');
        final preferences = await SharedPreferences.getInstance();
        await preferences.reload();
      } catch (_) {
        Error.throwWithStackTrace(error, stack);
      }
      await _initialize(report);
    }
  }

  Future<void> _initialize(void Function(String)? report) async {
    report?.call('打开聊天记录库');
    _messagesBox = await Hive.openBox<String>('messages');
    report?.call('打开会话资料库');
    _sessionsBox = await Hive.openBox<String>('sessions');
    report?.call('打开表情库');
    _emojisBox = await Hive.openBox<String>('emojis');
    report?.call('打开插件配置库');
    _pluginsBox = await Hive.openBox<String>('plugins');
    report?.call('打开插件数据存储');
    _pluginDataBox = await Hive.openBox<String>('plugin_data');
    report?.call('读取系统偏好设置');
    _prefs = await SharedPreferences.getInstance();
    report?.call('确认本地聊天数据所属机器人');
    selectChatAccount(getBotConfig().appId);
    // Legacy records belong ONLY to the bot configured before multi-bot support.
    // An unknown owner stays unassigned; never attach old OpenIDs to a new bot.
    if (!_prefs.containsKey('chat_legacy_owner')) {
      await _prefs.setString('chat_legacy_owner', getBotConfig().appId);
    }

    // 只迁移一次旧版的默认关闭状态，后续用户主动关闭不再被重置。
    final savedConfig = _prefs.getString('bot_config');
    if (savedConfig != null) {
      report?.call('迁移旧版偏好设置');
      final map = Map<String, dynamic>.from(jsonDecode(savedConfig) as Map);
      if (BotConfig.needsOiapiNicknameDefaultMigration(map)) {
        await _prefs.setString(
          'bot_config',
          jsonEncode({
            ...map,
            'enableOiapiNickname': true,
            'oiapiNicknameDefaultVersion':
                BotConfig.oiapiNicknameDefaultVersion,
          }),
        );
      }
    }
  }

  // --- Bot Config ---
  BotConfig getBotConfig() {
    final json = _prefs.getString('bot_config');
    if (json == null) return BotConfig();
    return BotConfig.fromMap(jsonDecode(json));
  }

  Future<void> saveBotConfig(BotConfig config) {
    final snapshot = BotConfig.fromMap(config.toMap());
    final pending = _configWrites.then((_) => _persistBotConfig(snapshot));
    _configWrites = pending.catchError((Object _) {});
    return pending;
  }

  Future<void> _persistBotConfig(BotConfig config) async {
    final profiles = {
      for (final bot in getBotProfiles()) bot.appId: bot.toMap(),
    };
    if (config.appId.isNotEmpty) profiles[config.appId] = config.toMap();
    if (!await _prefs.setString('bot_profiles', jsonEncode(profiles)) ||
        !await _prefs.setString('bot_config', jsonEncode(config.toMap()))) {
      throw StateError('无法保存机器人配置');
    }
  }

  List<BotConfig> getBotProfiles() {
    final saved = _prefs.getString('bot_profiles');
    final profiles = saved == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(saved) as Map);
    final active = getBotConfig();
    if (active.appId.isNotEmpty) profiles[active.appId] = active.toMap();
    return profiles.values
        .map((value) => BotConfig.fromMap(Map<String, dynamic>.from(value)))
        .toList();
  }

  String get _chatPrefix =>
      'bot:${base64Url.encode(utf8.encode(_chatAppId ?? getBotConfig().appId))}:';
  bool get _ownsLegacy =>
      (_chatAppId ?? getBotConfig().appId).isNotEmpty &&
      _prefs.getString('chat_legacy_owner') ==
          (_chatAppId ?? getBotConfig().appId);
  String _key(String id) => '$_chatPrefix$id';
  String? _read(Box<String> box, String id) =>
      box.get(_key(id)) ??
      (_ownsLegacy && !id.startsWith('bot:') ? box.get(id) : null);
  Iterable<String> _chatValues(Box<String> box) sync* {
    final prefix = _chatPrefix;
    // New scoped records override a legacy record with the same message ID.
    if (_ownsLegacy) {
      for (final key in box.keys.where(
        (key) => !key.toString().startsWith('bot:'),
      )) {
        if (!box.containsKey('$prefix$key')) yield box.get(key)!;
      }
    }
    for (final key in box.keys.where(
      (key) => key.toString().startsWith(prefix),
    )) {
      yield box.get(key)!;
    }
  }

  // --- Theme ---
  String getAppearance() {
    final value = _prefs.getString('appearance');
    if (['light', 'dark', 'system'].contains(value)) return value!;
    // Keep an existing user's explicit light/dark choice.
    if (_prefs.containsKey('theme_dark')) {
      return getThemeMode() ? 'dark' : 'light';
    }
    return 'system';
  }

  Future<void> setAppearance(String value) async {
    if (!['light', 'dark', 'system'].contains(value)) {
      throw ArgumentError.value(value, 'appearance');
    }
    if (!await _prefs.setString('appearance', value)) {
      throw StateError('主题选择未能保存');
    }
  }

  bool getThemeMode() => _prefs.getBool('theme_dark') ?? false;

  Future<void> setThemeMode(bool isDark) async {
    await _prefs.setBool('theme_dark', isDark);
  }

  // --- Messages ---
  Future<void> saveMessage(MessageModel message) async {
    await _messagesBox.put(_key(message.id), jsonEncode(message.toMap()));
  }

  Future<void> updateMessage(MessageModel message) async {
    await _messagesBox.put(_key(message.id), jsonEncode(message.toMap()));
  }

  List<MessageModel> getMessages(String sessionId) {
    return _chatValues(_messagesBox)
        .map((json) => MessageModel.fromMap(jsonDecode(json)))
        .where((m) => m.sessionId == sessionId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  MessageModel? getMessageById(String messageId) {
    final json = _read(_messagesBox, messageId);
    if (json == null) return null;
    return MessageModel.fromMap(jsonDecode(json));
  }

  Future<void> markMessageRead(String messageId) async {
    final json = _read(_messagesBox, messageId);
    if (json != null) {
      final msg = MessageModel.fromMap(jsonDecode(json));
      msg.isRead = true;
      await _messagesBox.put(_key(messageId), jsonEncode(msg.toMap()));
    }
  }

  Future<void> deleteMessage(String messageId) async {
    final keys = [
      _key(messageId),
      if (_ownsLegacy && !messageId.startsWith('bot:')) messageId,
    ];
    await _messagesBox.deleteAll(keys);
  }

  // --- Chat Sessions ---
  Future<void> saveSession(ChatSession session) async {
    await _sessionsBox.put(_key(session.id), jsonEncode(session.toMap()));
  }

  List<ChatSession> getSessions() {
    return _chatValues(
        _sessionsBox,
      ).map((json) => ChatSession.fromMap(jsonDecode(json))).toList()
      ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
  }

  Future<void> updateSessionLastMessage(
    String sessionId,
    String lastMessage,
    DateTime time, {
    bool incrementUnread = true,
  }) async {
    final json = _read(_sessionsBox, sessionId);
    if (json != null) {
      final session = ChatSession.fromMap(jsonDecode(json));
      if (incrementUnread) session.unreadCount++;
      await _sessionsBox.put(
        _key(sessionId),
        jsonEncode({
          ...session.toMap(),
          'lastMessage': lastMessage,
          'lastMessageTime': time.toIso8601String(),
          'unreadCount': session.unreadCount,
        }),
      );
    }
  }

  Future<void> markSessionRead(String sessionId) async {
    final json = _read(_sessionsBox, sessionId);
    if (json != null) {
      final session = ChatSession.fromMap(jsonDecode(json));
      session.unreadCount = 0;
      await _sessionsBox.put(_key(sessionId), jsonEncode(session.toMap()));
    }
  }

  // --- Emojis ---
  Future<void> saveEmoji(EmojiItem emoji) async {
    await _emojisBox.put(emoji.id, jsonEncode(emoji.toMap()));
  }

  List<EmojiItem> getEmojis({String? category}) {
    final emojis = _emojisBox.values
        .map((json) => EmojiItem.fromMap(jsonDecode(json)))
        .toList();
    if (category != null) {
      return emojis.where((e) => e.category == category).toList();
    }
    return emojis;
  }

  List<String> getEmojiCategories() {
    return getEmojis().map((e) => e.category).toSet().toList();
  }

  Future<void> deleteEmoji(String id) async {
    await _emojisBox.delete(id);
  }

  // --- Plugins ---
  Future<void> savePluginConfig(PluginInfo plugin) async {
    await _pluginsBox.put(plugin.id, jsonEncode(plugin.toMap()));
  }

  List<PluginInfo> getPluginConfigs() {
    return _pluginsBox.values
        .map((json) => PluginInfo.fromMap(jsonDecode(json)))
        .toList();
  }

  Future<void> deletePluginConfig(String id) async {
    await _pluginsBox.delete(id);
  }

  Future<void> clearPluginConfigs() async {
    await _pluginsBox.clear();
  }

  Future<Map<String, dynamic>> readPluginData(String scope) async {
    final value = _pluginDataBox.get(scope);
    return value == null
        ? {}
        : Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  Future<void> writePluginData(String scope, Map<String, dynamic> value) =>
      _pluginDataBox.put(scope, jsonEncode(value));

  // --- Export / Import ---
  String exportConfig() {
    final data = {
      'bot_config': getBotConfig().toMap(),
      'emojis': getEmojis().map((e) => e.toMap()).toList(),
      'plugins': getPluginConfigs().map((p) => p.toMap()).toList(),
      'export_date': DateTime.now().toIso8601String(),
    };
    return jsonEncode(data);
  }

  Future<void> importConfig(String jsonStr) async {
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (data.containsKey('bot_config')) {
      await saveBotConfig(BotConfig.fromMap(data['bot_config']));
    }
    if (data.containsKey('emojis')) {
      for (final e in (data['emojis'] as List)) {
        await saveEmoji(EmojiItem.fromMap(e));
      }
    }
    if (data.containsKey('plugins')) {
      for (final p in (data['plugins'] as List)) {
        await savePluginConfig(PluginInfo.fromMap(p));
      }
    }
  }

  // --- Clear all data ---
  Future<void> flush() async {
    await Future.wait([
      _messagesBox.flush(),
      _sessionsBox.flush(),
      _emojisBox.flush(),
      _pluginsBox.flush(),
      _pluginDataBox.flush(),
    ]);
  }

  Future<void> clearAll() async {
    await _messagesBox.clear();
    await _sessionsBox.clear();
    await _emojisBox.clear();
    await _pluginsBox.clear();
    await _pluginDataBox.clear();
    await _prefs.clear();
  }
}
