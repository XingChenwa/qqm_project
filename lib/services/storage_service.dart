import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/message.dart';
import '../models/config.dart';
import '../models/plugin.dart';

class StorageService {
  late Box<String> _messagesBox;
  late Box<String> _sessionsBox;
  late Box<String> _emojisBox;
  late Box<String> _pluginsBox;
  late SharedPreferences _prefs;

  Future<void> init() async {
    _messagesBox = await Hive.openBox<String>('messages');
    _sessionsBox = await Hive.openBox<String>('sessions');
    _emojisBox = await Hive.openBox<String>('emojis');
    _pluginsBox = await Hive.openBox<String>('plugins');
    _prefs = await SharedPreferences.getInstance();

    // 只迁移一次旧版的默认关闭状态，后续用户主动关闭不再被重置。
    final savedConfig = _prefs.getString('bot_config');
    if (savedConfig != null) {
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

  Future<void> saveBotConfig(BotConfig config) async {
    await _prefs.setString('bot_config', jsonEncode(config.toMap()));
  }

  // --- Theme ---
  bool getThemeMode() => _prefs.getBool('theme_dark') ?? false;

  Future<void> setThemeMode(bool isDark) async {
    await _prefs.setBool('theme_dark', isDark);
  }

  // --- Messages ---
  Future<void> saveMessage(MessageModel message) async {
    await _messagesBox.put(message.id, jsonEncode(message.toMap()));
  }

  Future<void> updateMessage(MessageModel message) async {
    await _messagesBox.put(message.id, jsonEncode(message.toMap()));
  }

  List<MessageModel> getMessages(String sessionId) {
    return _messagesBox.values
        .map((json) => MessageModel.fromMap(jsonDecode(json)))
        .where((m) => m.sessionId == sessionId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  MessageModel? getMessageById(String messageId) {
    final json = _messagesBox.get(messageId);
    if (json == null) return null;
    return MessageModel.fromMap(jsonDecode(json));
  }

  Future<void> markMessageRead(String messageId) async {
    final json = _messagesBox.get(messageId);
    if (json != null) {
      final msg = MessageModel.fromMap(jsonDecode(json));
      msg.isRead = true;
      await _messagesBox.put(messageId, jsonEncode(msg.toMap()));
    }
  }

  Future<void> deleteMessage(String messageId) async {
    await _messagesBox.delete(messageId);
  }

  // --- Chat Sessions ---
  Future<void> saveSession(ChatSession session) async {
    await _sessionsBox.put(session.id, jsonEncode(session.toMap()));
  }

  List<ChatSession> getSessions() {
    return _sessionsBox.values
        .map((json) => ChatSession.fromMap(jsonDecode(json)))
        .toList()
      ..sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
  }

  Future<void> updateSessionLastMessage(
    String sessionId,
    String lastMessage,
    DateTime time, {
    bool incrementUnread = true,
  }) async {
    final json = _sessionsBox.get(sessionId);
    if (json != null) {
      final session = ChatSession.fromMap(jsonDecode(json));
      if (incrementUnread) session.unreadCount++;
      await _sessionsBox.put(
        sessionId,
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
    final json = _sessionsBox.get(sessionId);
    if (json != null) {
      final session = ChatSession.fromMap(jsonDecode(json));
      session.unreadCount = 0;
      await _sessionsBox.put(sessionId, jsonEncode(session.toMap()));
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
    ]);
  }

  Future<void> clearAll() async {
    await _messagesBox.clear();
    await _sessionsBox.clear();
    await _emojisBox.clear();
    await _pluginsBox.clear();
    await _prefs.clear();
  }
}
