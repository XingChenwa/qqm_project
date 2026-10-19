import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_dispatcher.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'support/fakes.dart';

class CapturingPlugins extends PluginManager {
  PluginMessage? received;
  CapturingPlugins(super.storage);
  @override
  Future<List<PluginResponse>> processMessage(
    PluginMessage message, {
    String? onlyPluginId,
  }) async {
    received = message;
    return [];
  }
}

void main() {
  test('无当前角色时不得把历史缓存 owner/admin 提升为插件权限', () async {
    final storage = MemoryStorage(config: validConfig());
    final bot = BotClient(
      storage,
      apiService: RecordingApi(),
      webSocketService: TestGateway(),
    );
    final manager = CapturingPlugins(storage);
    addTearDown(bot.dispose);
    addTearDown(manager.dispose);
    final cachedOwner = incoming('cached-role').copyWith(
      senderRole: 'owner',
      extra: {'botAppId': bot.config.appId, 'isGroup': true, 'senderRole': ''},
    );
    await PluginDispatcher(bot, manager).process(cachedOwner);
    expect(manager.received!.senderRole, '');
  });
  test('只使用当前原始事件或规范化事件中的群角色', () async {
    final storage = MemoryStorage(config: validConfig());
    final bot = BotClient(
      storage,
      apiService: RecordingApi(),
      webSocketService: TestGateway(),
    );
    final manager = CapturingPlugins(storage);
    addTearDown(bot.dispose);
    addTearDown(manager.dispose);
    for (final extra in [
      {'senderRole': 'member'},
      {
        'senderRole': '',
        'extra': {
          'author': {'member_role': 'member'},
        },
      },
    ]) {
      final message = incoming('current-role').copyWith(
        senderRole: 'owner',
        extra: {'botAppId': bot.config.appId, 'isGroup': true, ...extra},
      );
      await PluginDispatcher(bot, manager).process(message);
      expect(manager.received!.senderRole, 'member');
    }
  });
}
