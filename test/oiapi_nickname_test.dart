import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/oiapi_service.dart';
import 'package:qq_bot_manager/services/profile_request_queue.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/settings_screen.dart';
import 'package:qq_bot_manager/ui/screens/main_screen.dart';

import 'api_service_test.dart' show RecordingAdapter;
import 'profile_sync_test.dart' show profileEvent;
import 'support/fakes.dart';
import 'websocket_service_test.dart' show until;

class FakeOiapi extends OiapiService {
  final calls = <(String, String)>[];
  String nickname = 'OIAPI 小明';
  bool fail = false;
  Completer<ApiResult<Map<String, dynamic>>>? deferred;

  @override
  Future<ApiResult<Map<String, dynamic>>> getNickname({
    required String appId,
    required String openId,
  }) async {
    calls.add((appId, openId));
    if (deferred != null) return deferred!.future;
    return fail
        ? ApiResult.failure('模拟 OIAPI 暂不可用')
        : ApiResult.success({'openid': openId, 'nickname': nickname});
  }
}

BotConfig nicknameConfig({bool enabled = true}) =>
    BotConfig(appId: '100312990', enableOiapiNickname: enabled);

BotClient nicknameBot(
  MemoryStorage storage,
  FakeOiapi api,
  TestGateway gateway,
) => BotClient(
  storage,
  apiService: RecordingApi(),
  webSocketService: gateway,
  oiapiService: api,
  nicknameRequests: ProfileRequestQueue(spacing: Duration.zero),
);

void main() {
  test('OIAPI 请求只携带 AppID/OpenID，不含 QQ 鉴权；严格读取 data.nickname', () async {
    final adapter = RecordingAdapter()
      ..response = {
        'code': 1,
        'message': '不能当作昵称使用的提示',
        'data': {'openid': 'user-openid', 'nickname': ' 小明 ', 'age': 18},
      };
    final api = OiapiService(adapter: adapter);
    addTearDown(api.dispose);
    final result = await api.getNickname(
      appId: '100312990',
      openId: 'user-openid',
    );
    expect(result.data, {'openid': 'user-openid', 'nickname': '小明'});
    final request = adapter.requests.single;
    expect(request.uri.origin + request.uri.path, OiapiService.endpoint);
    expect(request.method, 'GET');
    expect(request.queryParameters, {
      'appid': '100312990',
      'openid': 'user-openid',
    });
    expect(request.followRedirects, isFalse);
    expect(request.data, isNull);
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains(anyOf('authorization', 'cookie', 'x-union-appid'))),
    );
  });

  test('OIAPI 业务失败、空昵称、错误用户和错误字段类型均不会变成成功昵称', () async {
    final adapter = RecordingAdapter();
    final api = OiapiService(adapter: adapter);
    addTearDown(api.dispose);
    for (final payload in [
      {'code': -1, 'message': '参数错误'},
      {
        'code': 200,
        'data': {'openid': 'u', 'nickname': '误报成功'},
      },
      {
        'code': 1,
        'message': '提示不能作为昵称',
        'data': {'openid': 'u'},
      },
      {
        'code': 1,
        'data': {'openid': 'someone-else', 'nickname': '其他用户'},
      },
      {
        'code': 1,
        'data': {'openid': 'u', 'nickname': '  '},
      },
      {
        'code': 1,
        'data': {'openid': 'u', 'nickname': 123},
      },
      {
        'code': 1,
        'data': {'openid': 'u', 'nickname': '名' * 129},
      },
      'not a JSON object',
    ]) {
      adapter.response = payload;
      final result = await api.getNickname(appId: '100312990', openId: 'u');
      expect(result.isSuccess, isFalse, reason: '$payload');
      expect(result.data, isNull);
    }
  });

  test('OIAPI 拒绝超大响应，重定向或 HTTP 错误不会被跟随或当成昵称', () async {
    final adapter = RecordingAdapter()..response = {'large': 'x' * 70000};
    final api = OiapiService(adapter: adapter);
    addTearDown(api.dispose);
    expect(
      (await api.getNickname(appId: '100312990', openId: 'u')).isSuccess,
      isFalse,
    );
    for (final status in [302, 403, 500]) {
      adapter.status = status;
      adapter.response = {
        'code': 1,
        'data': {'openid': 'u', 'nickname': '不应采用'},
      };
      final result = await api.getNickname(appId: '100312990', openId: 'u');
      expect(result.isSuccess, isFalse);
      expect(result.error, contains('HTTP $status'));
    }
    expect(adapter.requests.length, 4);
  });

  test('缺少或无效的 AppID/OpenID 时不向第三方发请求', () async {
    final adapter = RecordingAdapter();
    final api = OiapiService(adapter: adapter);
    addTearDown(api.dispose);
    for (final input in [
      ('', 'u'),
      ('appid', 'u'),
      ('100312990', ''),
      ('100312990', 'u&token=x'),
    ]) {
      expect(
        (await api.getNickname(appId: input.$1, openId: input.$2)).isSuccess,
        isFalse,
      );
    }
    expect(adapter.requests, isEmpty);
  });

  test('新旧配置默认开启昵称查询，主动关闭及昵称来源缓存可持久保存', () {
    expect(BotConfig().enableOiapiNickname, isTrue);
    expect(BotConfig.fromMap({}).enableOiapiNickname, isTrue);
    expect(
      BotConfig.fromMap({'enableOiapiNickname': false}).enableOiapiNickname,
      isTrue,
    );
    expect(
      BotConfig.fromMap(nicknameConfig().toMap()).enableOiapiNickname,
      isTrue,
    );
    expect(
      BotConfig.fromMap(
        nicknameConfig(enabled: false).toMap(),
      ).enableOiapiNickname,
      isFalse,
    );
    final session = ChatSession(
      id: 'u',
      name: '小明',
      sessionType: 0,
      lastMessageTime: DateTime.now(),
      nicknameSource: 'oiapi',
      nicknameAppId: '100312990',
      nicknameUpdatedAt: DateTime(2026, 10, 15),
    );
    final restored = ChatSession.fromMap(
      session.copyWith(unreadCount: 2).toMap(),
    );
    expect(restored.nicknameSource, 'oiapi');
    expect(restored.nicknameAppId, '100312990');
    expect(restored.nicknameUpdatedAt, session.nicknameUpdatedAt);
    expect(ChatSession.fromMap({'id': 'u'}).nicknameSource, '');
  });

  test('主动关闭后不查询；开启后也不查询群聊或覆盖平台已有单聊昵称', () async {
    final storage = MemoryStorage(config: nicknameConfig(enabled: false));
    final api = FakeOiapi();
    final gateway = TestGateway();
    final bot = nicknameBot(storage, api, gateway);
    addTearDown(bot.dispose);
    gateway.events.add(profileEvent('off', group: false, session: 'u'));
    await until(() => bot.messages.isNotEmpty);
    await bot.refreshSessionProfile('u', force: true);
    expect(api.calls, isEmpty);
    await bot.updateConfig(nicknameConfig());
    gateway.events.add(profileEvent('group', name: '群成员'));
    gateway.events.add(
      profileEvent('qq-name', group: false, session: 'known', name: 'QQ 昵称'),
    );
    await until(() => bot.messages.length == 3);
    await bot.refreshSessionProfile('known', force: true);
    expect(api.calls, isEmpty);
    expect(
      bot.sessions.firstWhere((s) => s.id == 'known').nicknameSource,
      'qq',
    );
  });

  test('单聊昵称查询使用原事件 author.id，更新会话与历史占位且不发送额外消息', () async {
    final storage = MemoryStorage(config: BotConfig(appId: '100312990'));
    final api = FakeOiapi();
    final gateway = TestGateway();
    final qq = RecordingApi();
    final bot = BotClient(
      storage,
      apiService: qq,
      webSocketService: gateway,
      oiapiService: api,
      nicknameRequests: ProfileRequestQueue(spacing: Duration.zero),
    );
    addTearDown(bot.dispose);
    var received = 0;
    bot.onMessageReceived = (_) => received++;
    gateway.events.add({
      ...profileEvent('missing-name', group: false, session: 'normalized-user'),
      'extra': {
        'author': {'id': 'raw-author-openid'},
      },
    });
    await until(
      () =>
          bot.sessions.isNotEmpty &&
          bot.sessions.single.nicknameSource == 'oiapi',
    );
    await bot.refreshSessionProfile('normalized-user');
    expect(api.calls, [('100312990', 'raw-author-openid')]);
    expect(bot.sessions.single.name, api.nickname);
    expect(bot.messages.single.senderName, api.nickname);
    expect(storage.getMessageById('missing-name')!.senderName, api.nickname);
    expect(bot.sessions.single.unreadCount, 1);
    expect(received, 1);
    expect(qq.calls, isEmpty);
    final restartApi = FakeOiapi();
    final restart = nicknameBot(storage, restartApi, TestGateway());
    addTearDown(restart.dispose);
    restart.refresh();
    await restart.refreshSessionProfile('normalized-user');
    expect(restart.sessions.single.name, api.nickname);
    expect(restartApi.calls, isEmpty);
  });

  test('失败负缓存避免每条消息重复查询，手动刷新可以重试且失败不清空旧名称', () async {
    final storage = MemoryStorage(config: nicknameConfig());
    final api = FakeOiapi()..fail = true;
    final gateway = TestGateway();
    final bot = nicknameBot(storage, api, gateway);
    addTearDown(bot.dispose);
    gateway.events.add(profileEvent('fail', group: false, session: 'u'));
    await until(
      () =>
          bot.sessions.isNotEmpty &&
          bot.sessions.single.profileStatus.contains('未完成'),
    );
    await bot.refreshSessionProfile('u');
    gateway.events.add(profileEvent('fail-again', group: false, session: 'u'));
    await until(() => bot.messages.length == 2);
    await bot.refreshSessionProfile('u');
    expect(api.calls.length, 1);
    api.fail = false;
    await bot.refreshSessionProfile('u', force: true);
    expect(api.calls.length, 2);
    expect(bot.sessions.single.name, api.nickname);
    api.fail = true;
    await bot.refreshSessionProfile('u', force: true);
    expect(bot.sessions.single.name, api.nickname);
    expect(bot.sessions.single.nicknameSource, 'oiapi');
  });

  test('OIAPI 昵称缓存一小时，到期后补取新昵称，普通消息不反复查询', () async {
    final storage = MemoryStorage(config: nicknameConfig());
    final api = FakeOiapi();
    final gateway = TestGateway();
    final bot = nicknameBot(storage, api, gateway);
    addTearDown(bot.dispose);
    gateway.events.add(profileEvent('first-name', group: false, session: 'u'));
    await until(
      () =>
          bot.sessions.isNotEmpty &&
          bot.sessions.single.nicknameSource == 'oiapi',
    );
    await bot.refreshSessionProfile('u');
    gateway.events.add(profileEvent('cached-name', group: false, session: 'u'));
    await until(() => bot.messages.length == 2);
    await bot.refreshSessionProfile('u');
    expect(api.calls.length, 1);
    storage.storedSessions['u'] = bot.sessions.single.copyWith(
      nicknameUpdatedAt: DateTime.now().subtract(const Duration(hours: 2)),
    );
    bot.refresh();
    api.nickname = '改过的昵称';
    await bot.refreshSessionProfile('u');
    expect(api.calls.length, 2);
    expect(bot.sessions.single.name, '改过的昵称');
    expect(bot.messages.every((m) => m.senderName == '改过的昵称'), isTrue);
    await bot.updateConfig(
      BotConfig(appId: '100312991', enableOiapiNickname: true),
    );
    expect(bot.sessions, isEmpty);
    expect(api.calls.length, 2);
    gateway.events.add(
      profileEvent('new-bot-user', group: false, session: 'u'),
    );
    await until(
      () =>
          api.calls.length == 3 &&
          bot.sessions.single.nicknameSource == 'oiapi',
    );
    await bot.refreshSessionProfile('u');
    expect(api.calls.last.$1, '100312991');
    expect(bot.sessions.single.nicknameAppId, '100312991');
  });

  test('OIAPI 慢请求不能覆盖后来到达的 QQ 官方昵称、最新消息或未读数', () async {
    final storage = MemoryStorage(config: nicknameConfig());
    final api = FakeOiapi()..deferred = Completer();
    final gateway = TestGateway();
    final bot = nicknameBot(storage, api, gateway);
    addTearDown(bot.dispose);
    gateway.events.add(profileEvent('old', group: false, session: 'u'));
    await until(() => api.calls.isNotEmpty);
    gateway.events.add(
      profileEvent(
        'new',
        group: false,
        session: 'u',
        name: 'QQ 官方昵称',
        text: '最新消息',
      ),
    );
    await until(() => bot.messages.length == 2);
    api.deferred!.complete(
      ApiResult.success({'openid': 'u', 'nickname': '过时昵称'}),
    );
    await bot.refreshSessionProfile('u');
    expect(bot.sessions.single.name, 'QQ 官方昵称');
    expect(bot.sessions.single.nicknameSource, 'qq');
    expect(bot.sessions.single.lastMessage, '最新消息');
    expect(bot.sessions.single.unreadCount, 2);
    expect(bot.messages.last.senderName, 'QQ 官方昵称');
  });

  for (final switchAccount in [false, true]) {
    test('${switchAccount ? '切换机器人' : '关闭开关'}取消未发送的第三方查询，并忽略旧响应', () async {
      final storage = MemoryStorage(config: nicknameConfig());
      final api = FakeOiapi()..deferred = Completer();
      final gateway = TestGateway();
      final bot = nicknameBot(storage, api, gateway);
      addTearDown(bot.dispose);
      gateway.events.add(profileEvent('a', group: false, session: 'a'));
      await until(() => api.calls.isNotEmpty);
      gateway.events.add(profileEvent('b', group: false, session: 'b'));
      await until(() => bot.messages.length == 2);
      final newConfig = nicknameConfig(enabled: switchAccount);
      if (switchAccount) newConfig.appId = '100312991';
      await bot.updateConfig(newConfig);
      api.deferred!.complete(
        ApiResult.success({'openid': 'a', 'nickname': '旧响应'}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(api.calls.length, 1);
      expect(bot.sessions.any((s) => s.name == '旧响应'), isFalse);
      expect(bot.messages.any((m) => m.senderName == '旧响应'), isFalse);
    });
  }

  for (final width in [320.0, 960.0]) {
    testWidgets('OIAPI 在 $width 宽设置页移除会话资料入口且保存其他设置不关闭自动查询', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage();
      final api = FakeOiapi();
      final bot = nicknameBot(storage, api, TestGateway());
      addTearDown(bot.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<StorageService>.value(value: storage),
            ChangeNotifierProvider<BotClient>.value(value: bot),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();
      expect(find.text('会话资料'), findsNothing);
      expect(find.byKey(const ValueKey('oiapi-nickname-switch')), findsNothing);
      expect(find.text('保存资料设置'), findsNothing);
      await tester.ensureVisible(find.text('保存连接设置'));
      await tester.tap(find.text('保存连接设置'));
      await tester.pumpAndSettle();
      expect(storage.getBotConfig().enableOiapiNickname, isTrue);
      expect(bot.config.enableOiapiNickname, isTrue);
      expect(api.calls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('旧版关闭配置升级后启动即补全已选单聊昵称，无需打开设置或点击刷新', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const user = 'synthetic-user-openid';
    final storage = MemoryStorage(
      config: BotConfig.fromMap({
        'appId': '100312990',
        'enableOiapiNickname': false,
      }),
    );
    storage.storedSessions[user] = ChatSession(
      id: user,
      name: '用户-$user',
      sessionType: 0,
      unreadCount: 3,
      lastMessageTime: DateTime.now(),
    );
    final api = FakeOiapi();
    final gateway = TestGateway();
    final bot = nicknameBot(storage, api, gateway);
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
    expect(api.calls, [('100312990', user)]);
    expect(bot.sessions.single.name, api.nickname);
    expect(storage.storedSessions[user]!.name, api.nickname);
    expect(bot.sessions.single.unreadCount, 3);
    expect(bot.messages, isEmpty);
    expect(find.text(api.nickname), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
