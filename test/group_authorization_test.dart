import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qqm_plugins/group_authorization/plugin.dart';
import 'package:qqm_plugins/sdk.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/screens/main_screen.dart';

import 'support/fakes.dart';

PluginMessage command(
  String text, {
  String role = 'owner',
  bool group = true,
}) => PluginMessage(
  messageId: 'source',
  sessionId: 'group-openid',
  senderId: 'owner-openid',
  senderName: '群主',
  content: text,
  messageType: 0,
  isGroup: group,
  senderRole: role,
  timestamp: DateTime.now(),
);

const robots =
    '{"bot-a":{"bot_qq":"987654321","bot_uid":"u_bot_a"},"bot-b":{"bot_qq":"987654322","bot_uid":"u_bot_b"}}';

void main() {
  test('插件跳转按钮拒绝凭据、脚本、错误用户 ID 和 URL／回调冲突', () {
    for (final button in [
      {'label': '测试', 'data': 'javascript:alert(1)', 'url': true},
      {'label': '测试', 'data': 'https://user:secret@example.com', 'url': true},
      {
        'label': '测试',
        'data': 'https://example.com',
        'url': true,
        'callback': true,
      },
      {
        'label': '测试',
        'data': '/测试',
        'user_ids': ['invalid"id'],
      },
      {'label': '测试', 'data': '/测试', 'user_ids': 'not an array'},
    ]) {
      expect(
        () => PluginReply.fromMap({
          'format': 'markdown',
          'content': '测试',
          'buttons': [
            [button],
          ],
        }),
        throwsFormatException,
      );
    }
  });
  test('所有新插件默认关闭，手动开启状态和关闭状态重启保留', () async {
    final storage = MemoryStorage();
    var manager = TestPluginManager(storage);
    await manager.init();
    expect(manager.plugins, hasLength(7));
    expect(manager.enabledCount, 0);
    expect(await manager.processMessage(command('/主动消息')), isEmpty);
    expect(await manager.enablePlugin('group_authorization'), true);
    expect(manager.enabledCount, 1);
    manager.dispose();
    manager = TestPluginManager(storage);
    await manager.init();
    expect(manager.enabledCount, 1);
    expect(
      manager.plugins.singleWhere((p) => p.info.isEnabled).info.id,
      'group_authorization',
    );
    await manager.disablePlugin('group_authorization');
    manager.dispose();
    manager = TestPluginManager(storage);
    await manager.init();
    expect(manager.enabledCount, 0);
    manager.dispose();
  });

  test('先提供填写群号指令按钮，群主提交后才生成限定群主的链接', () async {
    final plugin = GroupAuthorizationPlugin(
      PluginInfo(
        id: 'group_authorization',
        name: '',
        version: '1',
        description: '',
        directory: '',
        config: {'robots_json': robots},
      ),
    );
    var appId = 'bot-a';
    plugin.host = PluginHost(
      store: () => PluginStore(() async => {}, (_) async {}),
      help: () => '',
      appId: () => appId,
    );
    await plugin.onEnable();
    final prompt = (await plugin.execute(command('/主动消息')))!;
    expect(prompt.format, 'markdown');
    expect(prompt.buttons.single.single.data, '/主动消息 ');
    expect(prompt.buttons.single.single.url, false);
    expect(prompt.buttons.single.single.userIds, ['owner-openid']);
    final reply = (await plugin.execute(command('/主动消息 123456789')))!;
    final button = reply.buttons.single.single;
    expect(button.label, '主动权限(群主使用)');
    expect(button.url, true);
    expect(button.userIds, ['owner-openid']);
    final uri = Uri.parse(button.data);
    expect(uri.host, 'club.vip.qq.com');
    expect(uri.path, '/transfer');
    expect(jsonDecode(uri.queryParameters['open_kuikly_info']!), {
      'page_name': 'ai_group_service_agreement_pop_page',
      'groupCode': 123456789,
      'botUin': 987654321,
      'botUid': 'u_bot_a',
      'screen': 1,
    });
    expect(PluginReply.fromMap(reply.toMap()).buttons.single.single.userIds, [
      'owner-openid',
    ]);
    appId = 'bot-b';
    final other = (await plugin.execute(command('/主动消息 123456789')))!;
    expect(
      jsonDecode(
        Uri.parse(
          other.buttons.single.single.data,
        ).queryParameters['open_kuikly_info']!,
      )['botUid'],
      'u_bot_b',
    );
    appId = 'unknown-bot';
    expect(
      (await plugin.execute(command('/主动消息 123456789')))!.buttons,
      isEmpty,
    );
    expect(plugin.acceptsUnmentioned(command('/主动消息')), false);
  });

  test('拒绝管理员、普通成员、未知身份及非法群号；单聊不生成授权入口', () async {
    final plugin = GroupAuthorizationPlugin(
      PluginInfo(
        id: 'group_authorization',
        name: '',
        version: '1',
        description: '',
        directory: '',
        config: {'robots_json': robots},
      ),
    );
    for (final role in ['admin', 'member', '', 'operator']) {
      final reply = (await plugin.execute(
        command('/主动消息 123456789', role: role),
      ))!;
      expect(reply.buttons, isEmpty);
      expect(reply.content, contains('只有群主本人'));
    }
    for (final value in [
      'group-openid',
      '123',
      '123456789&botUid=x',
      '123456789 987654321',
    ]) {
      expect((await plugin.execute(command('/主动消息 $value')))!.buttons, isEmpty);
    }
    expect(
      (await plugin.execute(command('/主动消息', group: false)))!.buttons,
      isEmpty,
    );
    expect(await plugin.execute(command('主动消息')), isNull);
    expect(await plugin.execute(command('/其他命令')), isNull);
  });

  test('无效机器人 JSON 不启用，不能注入自定义跳转地址或查询参数', () async {
    for (final source in [
      'not json',
      '[]',
      '{"bot-a":{"bot_qq":"987654321","bot_uid":"u&x=1"}}',
      '{"bot-a":{"bot_qq":"987654321","bot_uid":"u_ok","url":"https://evil.example"}}',
    ]) {
      final plugin = GroupAuthorizationPlugin(
        PluginInfo(
          id: 'group_authorization',
          name: '',
          version: '1',
          description: '',
          directory: '',
          config: {'robots_json': source},
        ),
      );
      await expectLater(plugin.onEnable(), throwsFormatException);
    }
  });

  for (final delivery in ['at', 'full-tag', 'full-display', 'full-stripped']) {
    testWidgets('群 @ 指令发送两步键盘且权限正确：$delivery', (tester) async {
      final storage = MemoryStorage(
        config: validConfig()
          ..appId = 'bot-a'
          ..clientSecret = '',
      );
      final manager = TestPluginManager(storage);
      final gateway = TestGateway();
      final api = RecordingApi();
      final bot = BotClient(
        storage,
        apiService: api,
        webSocketService: gateway,
      );
      addTearDown(manager.dispose);
      addTearDown(bot.dispose);
      await tester.runAsync(manager.init);
      await manager.updatePluginConfig('group_authorization', {
        'robots_json': robots,
      });
      await manager.enablePlugin('group_authorization');
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<StorageService>.value(value: storage),
            ChangeNotifierProvider<BotClient>.value(value: bot),
            ChangeNotifierProvider<PluginManager>.value(value: manager),
          ],
          child: MaterialApp(
            home: MainScreen(toggleTheme: () {}, themeMode: ThemeMode.light),
          ),
        ),
      );
      await tester.pumpAndSettle();
      gateway.onReady?.call({
        'user': {'id': 'current-bot', 'username': '薯条很乖巧'},
      });
      await tester.pumpAndSettle();
      Map<String, dynamic> event(
        String id,
        String text,
        String role,
        String user,
      ) {
        final raw = switch (delivery) {
          'full-tag' => '<@!current-bot> $text',
          'full-display' => '@薯条很乖巧 $text',
          _ => text,
        };
        return {
          'id': id,
          'sessionId': 'group-openid',
          'senderId': user,
          'senderName': '用户',
          'content': raw,
          'rawContent': raw,
          'senderRole': role,
          'isGroup': true,
          'timestamp': DateTime.now(),
          'eventType': delivery == 'at'
              ? 'GROUP_AT_MESSAGE_CREATE'
              : 'GROUP_MESSAGE_CREATE',
          'mentions': [
            {'id': 'current-bot', 'username': '薯条很乖巧', 'bot': true},
          ],
        };
      }

      for (final other in [false, true]) {
        gateway.events.add({
          ...event(
            'not-for-bot-$other',
            '/主动消息 938017865',
            'owner',
            'owner-openid',
          ),
          'eventType': 'GROUP_MESSAGE_CREATE',
          'content': other ? '@其他机器人 /主动消息 938017865' : '/主动消息 938017865',
          'rawContent': other
              ? '<@!other-bot> /主动消息 938017865'
              : '/主动消息 938017865',
          'mentions': [
            if (other) {'id': 'other-bot', 'username': '其他机器人', 'bot': true},
          ],
        });
        await tester.pumpAndSettle();
        expect(api.calls, isEmpty);
      }
      gateway.events.add(
        event('prompt-source', '/主动消息', 'member', 'member-openid'),
      );
      await tester.pumpAndSettle();
      expect(api.calls, hasLength(1));
      gateway.events.add({
        ...event('prompt-source', '/主动消息', 'member', 'member-openid'),
        'eventType': 'GROUP_AT_MESSAGE_CREATE',
        'content': '/主动消息',
        'rawContent': '/主动消息',
      });
      await tester.pumpAndSettle();
      expect(api.calls, hasLength(1), reason: '全量与 @ 重复推送不能生成两个按钮');
      final prompt = api.calls.single['body'] as Map;
      expect(prompt['msg_type'], 2);
      expect(
        prompt['keyboard']['content']['rows'][0]['buttons'][0]['action']['type'],
        2,
      );
      gateway.events.add(
        event('link-source', '/主动消息 938017865', 'owner', 'owner-openid'),
      );
      await tester.pumpAndSettle();
      expect(api.calls, hasLength(2));
      final body = api.calls.last['body'] as Map;
      final button = body['keyboard']['content']['rows'][0]['buttons'][0];
      expect(body['msg_type'], 2);
      expect(body['msg_id'], 'link-source');
      expect(button['action']['type'], 0);
      expect(button['action']['permission'], {
        'type': 0,
        'specify_user_ids': ['owner-openid'],
      });
      expect(button['render_data']['label'], '主动权限(群主使用)');
      expect(button['render_data']['visited_label'], '主动权限(群主使用)');
      expect(button['action'].containsKey('enter'), false);
      expect(
        jsonDecode(
          Uri.parse(
            button['action']['data'] as String,
          ).queryParameters['open_kuikly_info']!,
        )['groupCode'],
        938017865,
      );
      expect(
        bot.messages
            .singleWhere((message) => message.id == 'link-source')
            .content,
        event(
          'link-source',
          '/主动消息 938017865',
          'owner',
          'owner-openid',
        )['content'],
        reason: '仅规范化插件输入，不改动收到的原消息',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
