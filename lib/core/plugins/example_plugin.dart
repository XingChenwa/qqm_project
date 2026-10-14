import '../../models/plugin.dart';

class ExamplePlugin extends BotPlugin {
  ExamplePlugin(super.info);

  @override
  Future<void> onEnable() async {}

  @override
  Future<void> onDisable() async {}

  @override
  Future<String?> onMessage(PluginMessage message) async {
    final content = message.content.trim().toLowerCase();
    if (content.isEmpty) return null;

    if (content.contains('你好') || content.contains('hello')) {
      return '你好，我是 QQ 机器人助手。发送 /help 可以查看可用命令。';
    }
    if (content.contains('帮助') || content == 'help') {
      return _helpText;
    }
    if (content == 'ping' || content.contains('/ping')) {
      return 'pong!';
    }
    if (content.contains('时间') || content.contains('几点')) {
      return '现在是 ${DateTime.now().toLocal().toString().substring(0, 19)}';
    }

    return null;
  }

  @override
  Future<String?> onCommand(String command, List<String> args) async {
    return switch (command) {
      'help' => _helpText,
      'ping' => 'pong!',
      _ => null,
    };
  }

  static const _helpText = '''
可用命令：
/help - 显示帮助
/ping - 测试响应
天气 <城市>、查询天气 <城市> 或 /天气 <城市> - 高德实况天气
查ip地址 <IPv4> 或 /ip <IPv4> - 高德 IP 定位
/dice 或 /roll 2d6 - 掷骰子
/translate ```代码``` - 翻译代码注释
''';
}
