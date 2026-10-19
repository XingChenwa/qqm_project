import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/utils/bot_command_context.dart';
import 'package:qq_bot_manager/models/plugin.dart';

void main() {
  const text = '/主动消息 938017865';
  const name = '薯条很乖巧';

  test('全量消息只移除属于当前机器人的标签，兼容两种 QQ @ 写法', () {
    for (final tag in [
      '<@bot-self>',
      '<@!bot-self>',
      '<qqbot-at-user id="bot-self" />',
    ]) {
      final result = botCommandContext(
        '$tag $text',
        isGroup: true,
        eventType: 'GROUP_MESSAGE_CREATE',
        botId: 'bot-self',
      );
      expect(result.isMentioned, true);
      expect(result.content, text);
    }
  });

  test('mentions 确认当前机器人后，支持昵称前缀和平台已去前缀的正文', () {
    for (final content in ['@$name $text', text]) {
      final result = botCommandContext(
        content,
        isGroup: true,
        eventType: 'GROUP_MESSAGE_CREATE',
        botId: 'bot-self',
        mentions: [
          {'member_openid': 'bot-self', 'username': name, 'bot': true},
        ],
      );
      expect(result.isMentioned, true);
      expect(result.content, text);
    }
  });

  test('本次事件明确的 self 标记可关联不同身份域下的 OpenID，不猜测 AppID', () {
    final result = botCommandContext(
      '<qqbot-at-user id="group-bot-openid" /> $text',
      isGroup: true,
      eventType: 'GROUP_MESSAGE_CREATE',
      botId: 'ready-bot-id',
      mentions: [
        {
          'id': 'ready-bot-id',
          'member_openid': 'group-bot-openid',
          'is_you': true,
          'username': name,
        },
      ],
    );
    expect(result.isMentioned, true);
    expect(result.content, text);
    final selfOnly = botCommandContext(
      '<@group-bot-openid> $text',
      isGroup: true,
      eventType: 'GROUP_MESSAGE_CREATE',
      mentions: [
        {'id': 'group-bot-openid', 'is_you': true},
      ],
    );
    expect(selfOnly.isMentioned, true);
    expect(selfOnly.content, text);
  });

  test('普通全量命令、其他机器人、同名其他账号不能冒充当前机器人的 @', () {
    for (final content in [text, '<@other> $text', '@$name $text']) {
      final result = botCommandContext(
        content,
        isGroup: true,
        eventType: 'GROUP_MESSAGE_CREATE',
        botId: 'current',
        botName: name,
        mentions: [
          {'id': 'other', 'bot': true, 'is_you': false, 'username': name},
        ],
      );
      expect(result.isMentioned, false);
      expect(result.content, content);
    }
    expect(
      botCommandContext(
        text,
        isGroup: true,
        eventType: 'GROUP_MESSAGE_CREATE',
        botName: name,
      ).isMentioned,
      false,
    );
  });

  test('缺少结构化 recipients 时仅精确匹配当前昵称，不吞掉后缀或命令参数', () {
    final result = botCommandContext(
      '  @$name\u2005$text',
      isGroup: true,
      eventType: 'GROUP_MESSAGE_CREATE',
      botName: name,
    );
    expect(result.isMentioned, true);
    expect(result.content, text);
    expect(
      botCommandContext(
        '@$name的朋友 $text',
        isGroup: true,
        eventType: 'GROUP_MESSAGE_CREATE',
        botName: name,
      ).isMentioned,
      false,
    );
    const body = '```python\nif True:\n    print("hello")\n```';
    expect(
      botCommandContext(
        '<@current> /translate $body',
        isGroup: true,
        eventType: 'GROUP_MESSAGE_CREATE',
        botId: 'current',
      ).content,
      '/translate $body',
    );
  });

  test('私聊和非消息事件不移除文字，旧 @ 事件不依赖 READY 身份资料', () {
    const original = '<@unknown> $text';
    final direct = botCommandContext(
      original,
      isGroup: true,
      eventType: 'GROUP_AT_MESSAGE_CREATE',
    );
    expect(direct.content, text);
    expect(direct.isMentioned, true);
    for (final group in [false, true]) {
      final result = botCommandContext(
        original,
        isGroup: group,
        eventType: 'C2C_MESSAGE_CREATE',
      );
      expect(result.content, original);
      expect(result.isMentioned, false);
    }
  });

  test('插件上下文传递实际 @ 状态但保留全量事件身份', () {
    final message = PluginMessage(
      messageId: 'source',
      sessionId: 'group',
      senderId: 'owner',
      senderName: '群主',
      content: text,
      messageType: 0,
      isGroup: true,
      isFullGroupMessage: true,
      isMentioned: true,
      timestamp: DateTime.now(),
    );
    expect(message.toMap()['is_mentioned'], true);
    expect(message.toMap()['is_full_group_message'], true);
  });
}
