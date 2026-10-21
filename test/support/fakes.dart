import 'dart:async';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/core/plugins/script_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/models/outgoing_message.dart';
import 'package:qq_bot_manager/models/group_notice.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/services/websocket_service.dart';

class TestPluginManager extends PluginManager {
  TestPluginManager(super.storage)
    : super(scriptRunnerFactory: PluginScriptRunner.forTesting);
}

class MemoryStorage extends StorageService {
  final groupNotices = <String, List<GroupNotice>>{};
  @override
  List<GroupNotice> getGroupNotices(String appId) =>
      List.of(groupNotices[appId] ?? []);
  @override
  Future<void> saveGroupNotices(String appId, List<GroupNotice> notices) async {
    groupNotices[appId] = List.of(notices);
  }

  bool mobileNotifications = false;
  @override
  bool getSystemNotificationsEnabled() => mobileNotifications;
  @override
  Future<void> setSystemNotificationsEnabled(bool value) async {
    mobileNotifications = value;
  }

  BotConfig config;
  final storedMessages = <String, MessageModel>{};
  final storedSessions = <String, ChatSession>{};
  final profiles = <String, BotConfig>{};
  @override
  List<BotConfig> getBotProfiles() => {
    ...profiles,
    if (config.appId.isNotEmpty) config.appId: config,
  }.values.map((bot) => BotConfig.fromMap(bot.toMap())).toList();

  final storedPlugins = <String, PluginInfo>{};
  final pluginData = <String, Map<String, dynamic>>{};

  String? _selectedChatAppId;
  final _messageAccounts = <String, Map<String, MessageModel>>{};
  final _sessionAccounts = <String, Map<String, ChatSession>>{};
  @override
  void selectChatAccount(String appId) {
    if (_selectedChatAppId != null && _selectedChatAppId != appId) {
      _messageAccounts[_selectedChatAppId!] = Map.of(storedMessages);
      _sessionAccounts[_selectedChatAppId!] = Map.of(storedSessions);
      storedMessages
        ..clear()
        ..addAll(_messageAccounts[appId] ?? {});
      storedSessions
        ..clear()
        ..addAll(_sessionAccounts[appId] ?? {});
    }
    _selectedChatAppId = appId;
    super.selectChatAccount(appId);
  }

  @override
  Future<Map<String, dynamic>> readPluginData(String scope) async =>
      pluginData[scope] ?? {};

  @override
  Future<void> writePluginData(String scope, Map<String, dynamic> value) async {
    pluginData[scope] = value;
  }

  MemoryStorage({BotConfig? config}) : config = config ?? BotConfig() {
    TestWidgetsFlutterBinding.ensureInitialized();
  }

  @override
  BotConfig getBotConfig() => BotConfig.fromMap(config.toMap());

  @override
  Future<void> saveBotConfig(BotConfig config) async {
    if (this.config.appId.isNotEmpty) {
      profiles[this.config.appId] = getBotConfig();
    }
    this.config = BotConfig.fromMap(config.toMap());
    if (config.appId.isNotEmpty) profiles[config.appId] = getBotConfig();
  }

  @override
  List<MessageModel> getMessages(String? sessionId) => storedMessages.values
      .where((m) => sessionId == null || m.sessionId == sessionId)
      .toList();

  @override
  MessageModel? getMessageById(String messageId) => storedMessages[messageId];

  @override
  Future<void> saveMessage(MessageModel message) async =>
      storedMessages[message.id] = message;

  @override
  Future<void> updateMessage(MessageModel message) => saveMessage(message);

  @override
  List<ChatSession> getSessions() => storedSessions.values.toList();

  @override
  Future<void> saveSession(ChatSession session) async =>
      storedSessions[session.id] = session;

  @override
  Future<void> updateSessionLastMessage(
    String sessionId,
    String lastMessage,
    DateTime time, {
    bool incrementUnread = true,
  }) async {
    final previous = storedSessions[sessionId];
    if (previous == null) return;
    storedSessions[sessionId] = previous.copyWith(
      lastMessageTime: time,
      lastMessage: lastMessage,
      unreadCount: previous.unreadCount + (incrementUnread ? 1 : 0),
    );
  }

  @override
  Future<void> markSessionRead(String sessionId) async {}

  @override
  List<PluginInfo> getPluginConfigs() => storedPlugins.values.toList();

  @override
  Future<void> savePluginConfig(PluginInfo plugin) async =>
      storedPlugins[plugin.id] = PluginInfo.fromMap(plugin.toMap());

  @override
  Future<void> deletePluginConfig(String id) async => storedPlugins.remove(id);

  @override
  List<EmojiItem> getEmojis({String? category}) => [];

  @override
  bool getThemeMode() => false;
  String? appearance;
  @override
  String getAppearance() => appearance ?? (getThemeMode() ? 'dark' : 'system');
  @override
  Future<void> setAppearance(String value) async => appearance = value;
}

BotConfig validConfig() => BotConfig(
  appId: 'test-app',
  clientSecret: 'test-secret',
  accessToken: 'valid-token',
  tokenExpiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
);

class RecordingApi extends ApiService {
  @override
  Future<ApiResult<bool>> removeGroupMembers({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    required List<String> memberIds,
  }) async => ApiResult.failure('测试：移除成员未授权', errorCode: 11253);
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupBotState({
    required String baseUrl,
    required String accessToken,
    required String groupId,
  }) async => ApiResult.failure('测试：群状态未授权', errorCode: 11253);
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupMuteSettings({
    required String baseUrl,
    required String accessToken,
    required String groupId,
  }) async => ApiResult.failure('测试：群禁言未授权', errorCode: 11253);
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupMembers({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    String cursor = '',
  }) async => ApiResult.failure('测试：群成员列表未授权', errorCode: 11253);
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupJoinRequests({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    String cursor = '',
    int limit = 20,
  }) async => ApiResult.failure('测试：群申请未授权', errorCode: 11253);
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupInfo({
    required String baseUrl,
    required String accessToken,
    required String groupId,
  }) async => ApiResult.failure('测试：群资料接口未授权', errorCode: 11253);

  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupMemberInfo({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    required String memberId,
  }) async => ApiResult.failure('测试：群成员接口未授权', errorCode: 11253);

  @override
  Future<ApiResult<Map<String, dynamic>>> getBotProfile({
    required String baseUrl,
    required String accessToken,
  }) async => ApiResult.success({'username': '测试机器人', 'avatar': ''});
  final calls = <Map<String, dynamic>>[];
  final interactionAcks = <String>[];
  int tokenRequests = 0;
  bool failSend = false;
  int? markdownErrorCode;

  @override
  Future<ApiResult<AccessTokenResult>> getAccessToken({
    required String appId,
    required String clientSecret,
  }) async {
    tokenRequests++;
    await Future<void>.delayed(Duration.zero);
    return ApiResult.success(
      AccessTokenResult(accessToken: 'refreshed-token', expiresIn: 7200),
    );
  }

  ApiResult<String> record(Map<String, dynamic> data) {
    calls.add(data);
    if (data['type'] == 2 && markdownErrorCode != null) {
      return ApiResult.failure('Markdown 被平台拒绝', errorCode: markdownErrorCode);
    }
    return failSend
        ? ApiResult.failure('测试发送失败')
        : ApiResult.success(
            'sent-${calls.length}',
            metadata: {
              'ext_info': {'ref_idx': 'REFIDX_sent-${calls.length}'},
            },
          );
  }

  @override
  Future<ApiResult<String>> sendConfiguredMessage({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    required OutgoingMessage message,
    bool isGroup = false,
    String? msgId,
    String? eventId,
    int? msgSeq,
    String? referenceId,
  }) async => record({
    'token': accessToken,
    'target': targetId,
    'content': message.content,
    'type': message.type,
    'isGroup': isGroup,
    'msgId': msgId,
    'eventId': eventId,
    'msgSeq': msgSeq,
    'referenceId': referenceId,
    'body': message.toPayload(
      messageId: msgId,
      eventId: eventId,
      sequence: msgSeq,
      referenceId: referenceId,
    ),
  });

  @override
  Future<ApiResult<bool>> acknowledgeInteraction({
    required String baseUrl,
    required String accessToken,
    required String interactionId,
    int code = 0,
  }) async {
    interactionAcks.add(interactionId);
    return ApiResult.success(true);
  }

  @override
  Future<ApiResult<String>> sendQQMessage({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    required String content,
    bool isGroup = false,
    String? msgId,
    int? msgSeq,
  }) async => record({
    'token': accessToken,
    'target': targetId,
    'content': content,
    'isGroup': isGroup,
    'msgId': msgId,
    'msgSeq': msgSeq,
    'type': 0,
  });

  @override
  Future<ApiResult<String>> sendQQMarkdown({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    String? markdownContent,
    String? templateId,
    List<Map<String, String>>? templateParams,
    bool isGroup = false,
    String? msgId,
    int? msgSeq,
  }) async => record({
    'token': accessToken,
    'target': targetId,
    'content': markdownContent,
    'isGroup': isGroup,
    'msgId': msgId,
    'msgSeq': msgSeq,
    'type': 2,
  });
}

class TestGateway extends WebSocketService {
  final events = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get messageStream => events.stream;

  @override
  void dispose() {
    events.close();
    super.dispose();
  }
}

MessageModel incoming(
  String id, {
  String session = 'group-1',
  String content = '你好',
  DateTime? timestamp,
}) => MessageModel(
  id: id,
  sessionId: session,
  senderId: 'member-1',
  senderName: '测试用户',
  content: content,
  messageType: 0,
  timestamp: timestamp ?? DateTime.now(),
  extra: {'isGroup': true},
);
