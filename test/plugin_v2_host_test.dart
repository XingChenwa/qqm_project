import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/main_screen.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('v2 Markdown 按钮经宿主发送；回调按官方事件 ID 回复并去重', (tester) async {
    final config = validConfig()
      ..appId = ''
      ..clientSecret = '';
    final storage = MemoryStorage(config: config);
    final manager = TestPluginManager(storage);
    final gateway = TestGateway();
    final api = RecordingApi();
    final bot = BotClient(storage, apiService: api, webSocketService: gateway);
    addTearDown(manager.dispose);
    addTearDown(bot.dispose);
    await tester.runAsync(manager.init);
    await manager.installPlugin(
      File('plugins/examples/buttons/plugin.json').readAsStringSync(),
    );
    await manager.enablePlugin('my_buttons');
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<StorageService>.value(value: storage),
          ChangeNotifierProvider<BotClient>.value(value: bot),
          ChangeNotifierProvider<PluginManager>.value(value: manager),
        ],
        child: const MaterialApp(
          home: MainScreen(toggleTheme: noop, themeMode: ThemeMode.light),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Map<String, dynamic> event(String type) => {
      'id': 'menu-source',
      'sessionId': 'g1',
      'senderId': 'u1',
      'senderName': '小明',
      'content': '/按钮菜单',
      'isGroup': true,
      'timestamp': DateTime.now(),
      'eventType': type,
    };
    gateway.events.add(event('GROUP_MESSAGE_CREATE'));
    gateway.events.add(event('GROUP_AT_MESSAGE_CREATE'));
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(1));
    final body = api.calls.single['body'] as Map;
    expect(body['msg_type'], 2);
    expect(body.containsKey('content'), false);
    expect(body['markdown']['content'], contains('插件菜单'));
    expect(
      body['keyboard']['content']['rows'][0]['buttons'][0]['action']['type'],
      2,
    );
    expect(
      body['keyboard']['content']['rows'][0]['buttons'][1]['action']['type'],
      1,
    );
    expect(
      body['keyboard']['content']['rows'][0]['buttons'][0]['action']
          .containsKey('enter'),
      false,
    );
    final callback = <String, dynamic>{
      'id': 'interaction-id',
      '_eventId': 'event-id',
      'type': 11,
      'group_openid': 'g1',
      'group_member_openid': 'u1',
      'data': {
        'resolved': {'button_data': 'qqm:my_buttons:hello'},
      },
    };
    gateway.onDispatch!('INTERACTION_CREATE', callback);
    gateway.onDispatch!('INTERACTION_CREATE', callback);
    await tester.pumpAndSettle();
    expect(api.interactionAcks, ['interaction-id']);
    expect(api.calls, hasLength(2));
    final reply = api.calls.last['body'] as Map;
    expect(reply['event_id'], 'event-id');
    expect(reply.containsKey('msg_id'), false);
    expect(reply['msg_type'], 0);
    expect(reply['content'], contains('收到你的按钮点击'));
    expect(bot.messages.where((m) => m.isFromBot), hasLength(2));
  });
}

void noop() {}
