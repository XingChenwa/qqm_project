import '../sdk.dart';

class ExamplePlugin extends BotPlugin {
  ExamplePlugin(super.info);

  @override
  List<PluginCommand> get commands => const [
    PluginCommand('帮助', '查看已启用插件的命令', aliases: ['help', '菜单']),
    PluginCommand('ping', '测试机器人响应'),
    PluginCommand('时间', '查看北京时间', aliases: ['time']),
    PluginCommand('复读', '原样发送一段文本（最多 1000 字）', usage: '复读 文本'),
  ];

  @override
  Future<void> onEnable() async {}

  @override
  Future<void> onDisable() async {}

  @override
  Future<String?> onMessage(PluginMessage message) async {
    final content = message.content.trim().toLowerCase();
    if (const ['你好', 'hello', 'hi'].contains(content)) {
      return '你好，我是 QQ 机器人助手。发送 /help 可以查看可用命令。';
    }
    return onCommand(content, const []);
  }

  @override
  Future<String?> onCommand(String command, List<String> args) async {
    return switch (command) {
      'help' || '帮助' || '菜单' || 'menu' => host?.help() ?? _helpText,
      'ping' => 'pong!',
      'time' || '时间' || '日期' || '几点' =>
        '北京时间：${DateTime.now().toUtc().add(const Duration(hours: 8)).toString().substring(0, 19)}',
      '复读' =>
        args.isEmpty
            ? '用法：/复读 文本'
            : args.join(' ').length > 1000
            ? '复读内容最多 1000 字。'
            : args.join(' '),
      _ => null,
    };
  }

  static const _helpText = '''
基础命令：
/帮助 或 #帮助 - 显示命令菜单
/ping - 测试响应
/时间 - 北京时间
/复读 文本 - 原样发送文本
''';
}
