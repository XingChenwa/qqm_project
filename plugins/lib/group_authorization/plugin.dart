import 'dart:convert';
import '../sdk.dart';

/// Two explicit commands; no pending state can cross groups or bot accounts.
class GroupAuthorizationPlugin extends BotPlugin {
  GroupAuthorizationPlugin(super.info);

  @override
  List<PluginCommand> get commands => const [
    PluginCommand('主动消息', '群主填写群号后获取主动消息授权按钮', usage: '主动消息 [本群群号]'),
  ];

  Map<String, dynamic> _robots() {
    final source = info.config['robots_json'] ?? '{}';
    if (source is! String || source.length > 8192) {
      throw const FormatException('机器人资料必须是 JSON 对象');
    }
    final data = jsonDecode(source);
    if (data is! Map<String, dynamic> || data.length > 32) {
      throw const FormatException('请按 AppID 配置，最多 32 个机器人');
    }
    for (final entry in data.entries) {
      final value = entry.value;
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(entry.key) ||
          value is! Map<String, dynamic> ||
          value.keys.any((key) => !{'bot_qq', 'bot_uid'}.contains(key)) ||
          !_number(value['bot_qq']) ||
          !_identifier(value['bot_uid'])) {
        throw const FormatException('每个 AppID 需填写机器人 QQ 和 UID');
      }
    }
    return data;
  }

  bool _number(dynamic value) =>
      (value is String || value is int) &&
      RegExp(r'^[1-9][0-9]{4,12}$').hasMatch(value.toString());
  bool _identifier(dynamic value) =>
      value is String && RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value);

  @override
  Future<void> onEnable() async {
    _robots();
  }

  @override
  Future<void> onDisable() async {}
  @override
  Future<String?> onMessage(PluginMessage message) async => null;
  @override
  Future<String?> onCommand(String command, List<String> args) async => null;
  @override
  bool acceptsUnmentioned(PluginMessage message) => false;

  @override
  Future<PluginReply?> execute(PluginMessage message) async {
    if (message.eventType == 'interaction') return null;
    final command = parseSlashCommand(message.content);
    if (command?.command != '主动消息') return null;
    if (!message.isGroup) {
      return const PluginReply('请在需要授权的 QQ 群中 @机器人发送 /主动消息。', format: 'text');
    }
    final owner = message.senderRole == 'owner' && _identifier(message.senderId)
        ? message.senderId
        : null;
    if (command!.args.isEmpty) {
      return PluginReply(
        '### 开通群主动消息\n\n请群主点击「填写群号」，在指令后补上本群真实群号再发送。\n\n例如：/主动消息 123456789\n\n填写群号不会自动授权，下一步仍需群主在 QQ 页面确认。',
        format: 'markdown',
        buttons: [
          [
            PluginButton(
              '填写群号(群主)',
              '/主动消息 ',
              userIds: owner == null ? const [] : [owner],
            ),
          ],
        ],
      );
    }
    if (owner == null) {
      return const PluginReply(
        '只有群主本人可以提交群号。请群主 @机器人发送 /主动消息 本群群号；无法从本次 QQ 事件确认群主身份时不会生成授权链接。',
        format: 'text',
      );
    }
    if (command.args.length != 1 || !_number(command.args.single)) {
      return const PluginReply(
        '请填写本群真实数字群号，例如：/主动消息 123456789。不要填写群 OpenID、群链接或其他文字。',
        format: 'text',
      );
    }
    final appId = host?.appId ?? '';
    final robot = _robots()[appId];
    if (robot == null) {
      return PluginReply(
        '请先在管理器「主动消息权限」插件中，按当前 AppID ${appId.isEmpty ? '（未配置）' : appId} 填写机器人 QQ 号和 UID，然后重试。',
        format: 'text',
      );
    }
    final url = Uri.https('club.vip.qq.com', '/transfer', {
      'open_kuikly_info': jsonEncode({
        'page_name': 'ai_group_service_agreement_pop_page',
        'groupCode': int.parse(command.args.single),
        'botUin': int.parse(robot['bot_qq'].toString()),
        'botUid': robot['bot_uid'],
        'screen': 1,
      }),
    });
    return PluginReply(
      '### 群主动消息授权\n\n群号：${command.args.single}\n\n请确认这是本群群号，再由群主点击下方按钮，在 QQ 页面确认授权。是否可开通及最终授权结果以 QQ 页面为准。',
      format: 'markdown',
      buttons: [
        [
          PluginButton(
            '主动权限(群主使用)',
            url.toString(),
            url: true,
            userIds: [owner],
          ),
        ],
      ],
    );
  }
}
