import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/message_handler.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/models/plugin.dart';
import 'package:qq_bot_manager/utils/helpers.dart';

import 'support/fakes.dart';

void main() {
  test('收到 /translate 多行代码时走命令处理，代码不会被拆成单行或返回错误用法', () async {
    final manager = PluginManager(MemoryStorage());
    addTearDown(manager.dispose);
    await manager.init();
    const code =
        '/translate ```python\n# comment\nif True:\n    print("hello")\n```';
    final responses = await manager.processMessage(
      PluginMessage(
        messageId: 'source',
        sessionId: 'group',
        senderId: 'member',
        senderName: '用户',
        content: code,
        messageType: 0,
        isGroup: true,
        timestamp: DateTime.now(),
      ),
    );
    expect(responses.single.content, contains('尚未配置'));
    expect(responses.single.content, isNot(contains('用法')));
    expect(parseSlashCommand(code)?.args.single, contains('\n    print'));
  });

  test('关键词按界面声明完整匹配，未匹配时才使用默认自动回复', () {
    final storage = MemoryStorage(
      config: BotConfig(
        enableAutoReply: true,
        keywordReplies: {'你好': '关键词回复'},
        defaultAutoReply: '默认回复',
      ),
    );
    final handler = MessageHandler(storage);
    expect(handler.processMessage(incoming('a', content: '你好')), '关键词回复');
    expect(handler.processMessage(incoming('b', content: '请说你好')), '默认回复');
    storage.config.enableAutoReply = false;
    handler.refreshConfig();
    expect(handler.processMessage(incoming('c', content: '你好')), isNull);
  });
}
