import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/profile_request_queue.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/main_screen.dart';
import 'package:qq_bot_manager/ui/widgets/profile_avatar.dart';
import 'package:qq_bot_manager/utils/profile_helpers.dart';

import 'support/fakes.dart';
import 'websocket_service_test.dart' show until;

class ProfileApi extends RecordingApi {
  final groupCalls = <String>[];
  final memberCalls = <(String, String)>[];
  Completer<ApiResult<Map<String, dynamic>>>? deferredGroup;
  bool denyGroup = false;
  String memberAvatar = '';

  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupInfo({
    required String baseUrl,
    required String accessToken,
    required String groupId,
  }) async {
    groupCalls.add(groupId);
    if (deferredGroup != null) return deferredGroup!.future;
    if (denyGroup) return ApiResult.failure('未授权', errorCode: 11253);
    return ApiResult.success({'group_openid': groupId, 'group_name': '读书分享会'});
  }

  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupMemberInfo({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    required String memberId,
  }) async {
    memberCalls.add((groupId, memberId));
    return ApiResult.success({
      'member_openid': memberId,
      'username': '小明',
      'member_role': 'admin',
      if (memberAvatar.isNotEmpty) 'avatar': memberAvatar,
    });
  }

  @override
  Future<ApiResult<Map<String, dynamic>>> getBotProfile({
    required String baseUrl,
    required String accessToken,
  }) async => ApiResult.success({
    'id': 'bot-id',
    'username': '小助手',
    'avatar': 'https://example.com/bot.png',
  });
}

class ProfileUiBot extends BotClient {
  ProfileUiBot(
    super.storage, {
    required super.apiService,
    required super.profileRequests,
  });
  @override
  Future<bool> connect() async => false;
}

Map<String, dynamic> profileEvent(
  String id, {
  bool group = true,
  String name = '',
  String avatar = '',
  String text = '你好',
  String session = 'g',
}) => {
  'id': id,
  'sessionId': session,
  'senderId': group ? 'member-openid' : session,
  'senderName': name,
  'senderNameIsFallback': name.isEmpty,
  'senderAvatarUrl': avatar,
  'isGroup': group,
  'content': text,
  'timestamp': DateTime.now(),
  'eventType': group ? 'GROUP_AT_MESSAGE_CREATE' : 'C2C_MESSAGE_CREATE',
};

void main() {
  test('资料字段兼容旧存储，头像只接受真实网页 URL，不把 OpenID 当 QQ 号拼接', () {
    for (final url in [
      'file:///secret',
      'javascript:alert(1)',
      'https://user:password@example.com/a.png',
      'not a url',
    ]) {
      expect(profileAvatar(url), '');
    }
    expect(
      profileAvatar('//example.com/user.png'),
      'https://example.com/user.png',
    );
    final session = ChatSession.fromMap({
      'id': 'g',
      'name': '测试',
      'sessionType': 1,
    });
    expect(session.profileUpdatedAt, isNull);
    final updated = session.copyWith(
      avatarUrl: 'https://example.com/group.png',
      profileStatus: '群名已同步',
      profileUpdatedAt: DateTime(2026, 10, 15),
      unreadCount: 3,
    );
    final restored = ChatSession.fromMap(updated.toMap());
    expect(restored.avatarUrl, updated.avatarUrl);
    expect(restored.profileStatus, updated.profileStatus);
    expect(restored.unreadCount, 3);
  });

  test('QQ 用户头像按 AppID + OpenID 生成固定 HTTPS CDN 地址，并拒绝路径注入', () {
    const openId = 'DE1931D5330620DBD07FB4A5422917B6';
    const expected = 'https://q.qlogo.cn/qqapp/100312990/$openId/640';
    expect(qqOpenIdAvatar('100312990', openId), expected);
    expect(qqOpenIdAvatar(' 100312990 ', ' $openId '), expected);
    expect(isQqOpenIdAvatar(expected), isTrue);
    expect(isQqOpenIdAvatar('$expected?token=secret'), isFalse);
    expect(isQqOpenIdAvatar('https://q.qlogo.cn.evil/qqapp/1/u/640'), isFalse);
    for (final appId in ['', 'test-app', '1/2', '{appid}', '1?secret=x']) {
      expect(qqOpenIdAvatar(appId, openId), '');
    }
    for (final id in ['', '../u', 'a/b', 'a?x=y', 'a#x', 'a%2Fb', 'a\nb']) {
      expect(qqOpenIdAvatar('100312990', id), '');
    }
    expect(
      userProfileAvatar('100312990', openId, [
        qqOpenIdAvatar('999999', 'old-user'),
        'https://example.com/actual.png',
      ]),
      'https://example.com/actual.png',
    );
    expect(
      userProfileAvatar('100312990', openId, [
        qqOpenIdAvatar('999999', 'old-user'),
      ]),
      expected,
    );
  });

  test('私聊缺失头像时列表、标题与消息使用用户 CDN，真实头像到达后优先保留', () async {
    const user = 'DE1931D5330620DBD07FB4A5422917B6';
    final config = validConfig()
      ..appId = '100312990'
      ..enableOiapiNickname = false;
    final storage = MemoryStorage(config: config);
    final api = ProfileApi();
    final gateway = TestGateway();
    final bot = BotClient(storage, apiService: api, webSocketService: gateway);
    addTearDown(bot.dispose);
    gateway.events.add(
      profileEvent('cdn-private', group: false, session: user),
    );
    await until(() => bot.messages.isNotEmpty);
    await bot.refreshSessionProfile(user);
    final expected = qqOpenIdAvatar(config.appId, user);
    expect(bot.messages.single.senderAvatarUrl, expected);
    expect(bot.getMessagesForSession(user).single.senderAvatarUrl, expected);
    expect(bot.sessions.single.avatarUrl, expected);
    expect(bot.sessions.single.profileStatus, contains('CDN'));
    expect(storage.getMessageById('cdn-private')!.senderAvatarUrl, expected);
    gateway.events.add(
      profileEvent(
        'actual-private',
        group: false,
        session: user,
        avatar: 'https://example.com/user.png',
      ),
    );
    await until(() => bot.messages.length == 2);
    gateway.events.add(
      profileEvent('blank-private', group: false, session: user),
    );
    await until(() => bot.messages.length == 3);
    expect(bot.messages.last.senderAvatarUrl, 'https://example.com/user.png');
    expect(bot.sessions.single.avatarUrl, 'https://example.com/user.png');
    expect(bot.sessions.single.profileStatus, contains('已接收用户头像'));
    expect(api.groupCalls, isEmpty);
    expect(api.memberCalls, isEmpty);
  });

  test('群成员 CDN 使用发送者 OpenID，不用群 OpenID，且不依赖资料查询权限', () async {
    final config = BotConfig(appId: '100312990');
    final storage = MemoryStorage(config: config);
    final api = ProfileApi();
    final gateway = TestGateway();
    final bot = BotClient(storage, apiService: api, webSocketService: gateway);
    addTearDown(bot.dispose);
    gateway.events.add(profileEvent('cdn-group', name: '群成员'));
    await until(() => bot.messages.isNotEmpty);
    expect(
      bot.messages.single.senderAvatarUrl,
      qqOpenIdAvatar(config.appId, 'member-openid'),
    );
    expect(bot.sessions.single.avatarUrl, '');
    expect(api.groupCalls, isEmpty);
    expect(api.memberCalls, isEmpty);
  });

  test('群成员接口返回真实头像后替换 CDN 备用头像，并供后续消息复用', () async {
    final config = validConfig()..appId = '100312990';
    final storage = MemoryStorage(config: config);
    final api = ProfileApi()
      ..memberAvatar = 'https://example.com/member-real.png';
    final gateway = TestGateway();
    final bot = BotClient(
      storage,
      apiService: api,
      webSocketService: gateway,
      profileRequests: ProfileRequestQueue(spacing: Duration.zero),
    );
    addTearDown(bot.dispose);
    gateway.events.add(profileEvent('cdn-to-api'));
    await until(
      () =>
          bot.messages.isNotEmpty &&
          bot.messages.first.senderAvatarUrl == api.memberAvatar,
    );
    expect(
      storage.getMessageById('cdn-to-api')!.senderAvatarUrl,
      api.memberAvatar,
    );
    gateway.events.add(profileEvent('reuse-api'));
    await until(() => bot.messages.length == 2);
    expect(bot.messages.last.senderAvatarUrl, api.memberAvatar);
    expect(bot.sessions.single.avatarUrl, '');
  });

  test('旧记录仅在原 AppID 显示，切换账号不复用 OpenID；新记录使用新 CDN', () async {
    final storage = MemoryStorage(
      config: BotConfig(appId: '100312990', enableOiapiNickname: false),
    );
    for (final session in ['old-user', 'old-group']) {
      storage.storedSessions[session] = ChatSession(
        id: session,
        name: session,
        sessionType: session == 'old-user' ? 0 : 1,
        lastMessageTime: DateTime.now(),
      );
      storage.storedMessages[session] = MessageModel(
        id: session,
        sessionId: session,
        senderId: 'old-user',
        senderName: '旧用户',
        content: '旧记录',
        messageType: 0,
        timestamp: DateTime.now(),
      );
    }
    final bot = BotClient(storage, apiService: ProfileApi());
    addTearDown(bot.dispose);
    bot.refresh();
    final oldUrl = qqOpenIdAvatar('100312990', 'old-user');
    expect(
      bot.sessions.firstWhere((s) => s.sessionType == 0).avatarUrl,
      oldUrl,
    );
    expect(bot.sessions.firstWhere((s) => s.sessionType == 1).avatarUrl, '');
    expect(
      bot.getMessagesForSession('old-group').single.senderAvatarUrl,
      oldUrl,
    );
    await bot.refreshSessionProfile('old-user');
    // Also cover a persisted fallback from the previous bot's AppID.
    storage.storedMessages['old-user'] = storage.storedMessages['old-user']!
        .copyWith(senderAvatarUrl: oldUrl);
    await bot.updateConfig(
      BotConfig(appId: '100312991', enableOiapiNickname: false),
    );
    expect(bot.sessions, isEmpty);
    expect(bot.getMessagesForSession('old-user'), isEmpty);
    expect(bot.getMessagesForSession('old-group'), isEmpty);
    await bot.addSession('new-user', isGroup: false);
    await storage.saveMessage(
      MessageModel(
        id: 'new-message',
        sessionId: 'new-user',
        senderId: 'new-user',
        senderName: '新用户',
        content: '新机器人消息',
        messageType: 0,
        timestamp: DateTime.now(),
      ),
    );
    expect(
      bot.sessions.single.avatarUrl,
      qqOpenIdAvatar('100312991', 'new-user'),
    );
    expect(
      bot.getMessagesForSession('new-user').single.senderAvatarUrl,
      qqOpenIdAvatar('100312991', 'new-user'),
    );
    await bot.updateConfig(BotConfig());
    expect(bot.sessions, isEmpty);
    expect(bot.getMessagesForSession('new-user'), isEmpty);
    await bot.switchBot('100312990');
    expect(
      bot.getMessagesForSession('old-user').single.senderAvatarUrl,
      oldUrl,
    );
    expect(
      bot.sessions.firstWhere((s) => s.sessionType == 0).avatarUrl,
      oldUrl,
    );
  });

  test('没有消息历史时也保留会话真实头像，不把机器人作者当普通用户拼接 CDN', () async {
    final storage = MemoryStorage(config: BotConfig(appId: '100312990'));
    storage.storedSessions['u'] = ChatSession(
      id: 'u',
      name: '已知用户',
      avatarUrl: 'https://example.com/session.png',
      sessionType: 0,
      lastMessageTime: DateTime.now(),
    );
    final gateway = TestGateway();
    final bot = BotClient(
      storage,
      apiService: ProfileApi(),
      webSocketService: gateway,
    );
    addTearDown(bot.dispose);
    bot.refresh();
    gateway.events.add(
      profileEvent('known-session', group: false, session: 'u'),
    );
    await until(() => bot.messages.isNotEmpty);
    expect(
      bot.messages.single.senderAvatarUrl,
      'https://example.com/session.png',
    );
    gateway.events.add({...profileEvent('bot-author'), 'senderIsBot': true});
    await until(() => bot.messages.length == 2);
    expect(bot.messages.last.senderAvatarUrl, '');
    bot.addLocalBotMessage('u', '本机机器人消息', 0);
    expect(bot.messages.last.senderAvatarUrl, '');
  });

  test('群名和成员昵称后台获取，头像只使用事件字段；不会把成员头像当群头像', () async {
    final storage = MemoryStorage(config: validConfig());
    final api = ProfileApi();
    final gateway = TestGateway();
    final bot = BotClient(
      storage,
      apiService: api,
      webSocketService: gateway,
      profileRequests: ProfileRequestQueue(spacing: Duration.zero),
    );
    addTearDown(bot.dispose);
    gateway.events.add(
      profileEvent('first', avatar: 'https://example.com/member.png'),
    );
    await until(
      () =>
          bot.sessions.isNotEmpty &&
          bot.sessions.first.name == '读书分享会' &&
          bot.messages.first.senderName == '小明',
    );
    expect(
      bot.messages.first.senderAvatarUrl,
      'https://example.com/member.png',
    );
    expect(bot.messages.first.senderRole, 'admin');
    expect(bot.sessions.first.avatarUrl, '');
    expect(bot.sessions.first.profileStatus, contains('未提供群头像'));
    expect(storage.getMessageById('first')!.senderName, '小明');
    gateway.events.add(profileEvent('second'));
    await until(() => bot.messages.length == 2);
    expect(bot.messages.last.senderName, '小明');
    expect(bot.messages.last.senderRole, 'admin');
    expect(bot.messages.last.senderAvatarUrl, 'https://example.com/member.png');
    await bot.refreshSessionProfile('g');
    expect(api.groupCalls, ['g']);
    expect(api.memberCalls, [('g', 'member-openid')]);
    expect(bot.sessions.first.unreadCount, 2);
  });

  test('私聊昵称和头像持久更新，空字段不覆盖已知资料，缺失时不调用不存在的用户接口', () async {
    final storage = MemoryStorage(config: validConfig());
    final api = ProfileApi();
    final gateway = TestGateway();
    final bot = BotClient(storage, apiService: api, webSocketService: gateway);
    addTearDown(bot.dispose);
    gateway.events.add(
      profileEvent(
        'p1',
        group: false,
        session: 'u',
        name: '小红',
        avatar: 'https://example.com/u.png',
      ),
    );
    await until(() => bot.messages.length == 1);
    gateway.events.add(profileEvent('p2', group: false, session: 'u'));
    await until(() => bot.messages.length == 2);
    expect(bot.sessions.single.name, '小红');
    expect(bot.sessions.single.avatarUrl, 'https://example.com/u.png');
    expect(bot.messages.last.senderName, '小红');
    expect(api.groupCalls, isEmpty);
    expect(api.memberCalls, isEmpty);
    gateway.events.add(
      profileEvent(
        'p3',
        group: false,
        session: 'u',
        name: '新昵称',
        avatar: 'https://example.com/new.png',
      ),
    );
    await until(() => bot.messages.length == 3);
    expect(bot.sessions.single.name, '新昵称');
    expect(bot.sessions.single.avatarUrl, 'https://example.com/new.png');
    final restart = BotClient(storage, apiService: api);
    addTearDown(restart.dispose);
    restart.refresh();
    expect(restart.sessions.single.name, '新昵称');
    expect(restart.sessions.single.avatarUrl, 'https://example.com/new.png');
  });

  test('重复事件可以补全姓名头像，但不会重复增加消息、未读或触发自动回复', () async {
    final storage = MemoryStorage();
    final gateway = TestGateway();
    final bot = BotClient(
      storage,
      apiService: ProfileApi(),
      webSocketService: gateway,
    );
    addTearDown(bot.dispose);
    var dispatches = 0;
    bot.onMessageReceived = (_) => dispatches++;
    gateway.events.add(profileEvent('same', group: false, session: 'u'));
    await until(() => bot.messages.isNotEmpty);
    gateway.events.add(
      profileEvent(
        'same',
        group: false,
        session: 'u',
        name: '补全昵称',
        avatar: 'https://example.com/u.png',
      ),
    );
    await until(() => bot.messages.first.senderName == '补全昵称');
    expect(bot.messages.length, 1);
    expect(bot.sessions.single.unreadCount, 1);
    expect(dispatches, 1);
    expect(bot.sessions.single.name, '补全昵称');
    expect(bot.sessions.single.avatarUrl, 'https://example.com/u.png');
  });

  test('升级后的旧私聊会话从已有消息恢复昵称头像，不必等对方重新发消息', () async {
    final storage = MemoryStorage();
    storage.storedSessions['u'] = ChatSession(
      id: 'u',
      name: '用户-u',
      sessionType: 0,
      lastMessageTime: DateTime.now(),
    );
    storage.storedMessages['old'] = MessageModel(
      id: 'old',
      sessionId: 'u',
      senderId: 'u',
      senderName: '历史昵称',
      senderAvatarUrl: 'https://example.com/existing.png',
      content: '已有消息',
      messageType: 0,
      timestamp: DateTime.now(),
    );
    final bot = BotClient(storage, apiService: ProfileApi());
    addTearDown(bot.dispose);
    bot.refresh();
    await bot.refreshSessionProfile('u');
    expect(bot.sessions.single.name, '历史昵称');
    expect(bot.sessions.single.avatarUrl, 'https://example.com/existing.png');
    expect(
      storage.getSessions().single.avatarUrl,
      'https://example.com/existing.png',
    );
  });

  test('白名单拒绝有明确提示并停止重复查询，手动刷新可以在授权后重试', () async {
    final storage = MemoryStorage(config: validConfig());
    final api = ProfileApi()..denyGroup = true;
    final bot = ProfileUiBot(
      storage,
      apiService: api,
      profileRequests: ProfileRequestQueue(spacing: Duration.zero),
    );
    addTearDown(bot.dispose);
    await bot.addSession('g', isGroup: true);
    await bot.refreshSessionProfile('g');
    expect(bot.sessions.single.profileStatus, contains('11253'));
    await bot.refreshSessionProfile('g');
    expect(api.groupCalls.length, 1);
    api.denyGroup = false;
    await bot.refreshSessionProfile('g', force: true);
    expect(bot.sessions.single.name, '读书分享会');
    expect(api.groupCalls.length, 2);
  });

  test('资料慢请求不会覆盖后来消息、未读和新事件群名；切换凭据后旧结果被丢弃', () async {
    final storage = MemoryStorage(config: validConfig());
    final gateway = TestGateway();
    final api = ProfileApi()..deferredGroup = Completer();
    final bot = BotClient(
      storage,
      apiService: api,
      webSocketService: gateway,
      profileRequests: ProfileRequestQueue(spacing: Duration.zero),
    );
    addTearDown(bot.dispose);
    gateway.events.add({
      ...profileEvent('first', name: '用户 A'),
      'groupName': '事件里的群名',
    });
    await until(() => api.groupCalls.length == 1);
    gateway.events.add({
      ...profileEvent('second', name: '用户 A', text: '最新消息'),
      'groupName': '更新后的群名',
    });
    await until(() => bot.messages.length == 2);
    api.deferredGroup!.complete(
      ApiResult.success({'group_openid': 'g', 'group_name': '过期群名'}),
    );
    await bot.refreshSessionProfile('g');
    expect(bot.sessions.single.name, '更新后的群名');
    expect(bot.sessions.single.lastMessage, '最新消息');
    expect(bot.sessions.single.unreadCount, 2);
    api.deferredGroup = Completer();
    final pending = bot.refreshSessionProfile('g', force: true);
    await until(() => api.groupCalls.length == 2);
    await bot.updateConfig(
      BotConfig(appId: 'different-app', clientSecret: 'new-secret'),
    );
    api.deferredGroup!.complete(
      ApiResult.success({'group_openid': 'g', 'group_name': '旧账号结果'}),
    );
    await pending;
    expect(bot.sessions, isEmpty);
    await bot.switchBot('test-app');
    expect(bot.sessions.single.name, '更新后的群名');
  });

  test('机器人资料接口补齐头像，发送气泡使用机器人自己的昵称和头像', () async {
    final storage = MemoryStorage(config: validConfig());
    final gateway = TestGateway();
    final bot = BotClient(
      storage,
      apiService: ProfileApi(),
      webSocketService: gateway,
    );
    addTearDown(bot.dispose);
    gateway.onReady?.call({
      'user': {'id': 'bot-id', 'username': '旧名字'},
      'session_id': 'ready',
    });
    await until(() => bot.botAvatarUrl.isNotEmpty);
    await bot.sendTextMessage('private', '你好');
    expect(bot.messages.last.senderName, '小助手');
    expect(bot.messages.last.senderAvatarUrl, 'https://example.com/bot.png');
  });

  test('资料查询队列去重、限流、权限负缓存以及停用取消', () async {
    final queue = ProfileRequestQueue(
      spacing: const Duration(milliseconds: 20),
    );
    addTearDown(queue.dispose);
    final times = <DateTime>[];
    Future<ApiResult<Map<String, dynamic>>> load() async {
      times.add(DateTime.now());
      return ApiResult.success({'name': 'ok'});
    }

    final first = queue.request(kind: 'group', key: 'same', load: load);
    final repeated = queue.request(kind: 'group', key: 'same', load: load);
    await Future.wait([
      first,
      repeated,
      queue.request(kind: 'member', key: 'two', load: load),
    ]);
    expect(times.length, 2);
    expect(
      times[1].difference(times[0]).inMilliseconds,
      greaterThanOrEqualTo(18),
    );
    var deniedCalls = 0;
    Future<ApiResult<Map<String, dynamic>>> denied() async {
      deniedCalls++;
      return ApiResult.failure('denied', errorCode: 11253);
    }

    await queue.request(kind: 'group', key: 'deny', load: denied);
    await queue.request(kind: 'group', key: 'another', load: denied);
    expect(deniedCalls, 1);
    expect(queue.isDenied('group'), isTrue);
    await queue.request(kind: 'group', key: 'retry', load: load, force: true);
    expect(queue.isDenied('group'), isFalse);
    final pending = queue.request(kind: 'member', key: 'cancel', load: load);
    queue.dispose();
    expect((await pending).isSuccess, isFalse);
  });

  testWidgets('后台同步群名立即刷新当前聊天标题；头像有占位且资料权限状态可见', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = MemoryStorage(config: validConfig());
    storage.storedSessions['g'] = ChatSession(
      id: 'g',
      name: '群聊-g',
      sessionType: 1,
      lastMessageTime: DateTime.now(),
    );
    final api = ProfileApi()..deferredGroup = Completer();
    final bot = ProfileUiBot(
      storage,
      apiService: api,
      profileRequests: ProfileRequestQueue(spacing: Duration.zero),
    );
    final plugins = TestPluginManager(storage);
    addTearDown(bot.dispose);
    addTearDown(plugins.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<BotClient>.value(value: bot),
          ChangeNotifierProvider<PluginManager>.value(value: plugins),
        ],
        child: MaterialApp(
          home: MainScreen(toggleTheme: () {}, themeMode: ThemeMode.light),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The UI test client never connects a real gateway; profile HTTP is mocked.
    final pending = bot.refreshSessionProfile('g');
    await tester.pump();
    api.deferredGroup!.complete(
      ApiResult.success({'group_openid': 'g', 'group_name': '已获取的真实群名'}),
    );
    await tester.pumpAndSettle();
    await pending;
    expect(find.text('已获取的真实群名'), findsAtLeastNWidgets(2));
    expect(
      tester
          .widgetList<ProfileAvatar>(find.byType(ProfileAvatar))
          .every((avatar) => avatar.url.isEmpty),
      isTrue,
    );
    await tester.tap(find.byTooltip('会话信息'));
    await tester.pumpAndSettle();
    expect(find.textContaining('平台未提供群头像'), findsOneWidget);
    expect(find.text('刷新会话资料'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
