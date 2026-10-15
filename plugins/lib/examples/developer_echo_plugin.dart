import '../sdk.dart';

/// Dart SDK 示例，不默认注册；接入方法见 docs/plugin-development.md。
class DeveloperEchoPlugin extends BotPlugin {
  DeveloperEchoPlugin(super.info);
  @override
  Future<void> onEnable() async {}
  @override
  Future<void> onDisable() async {}
  @override
  Future<String?> onMessage(PluginMessage message) async => null;
  @override
  Future<String?> onCommand(String command, List<String> args) async {
    if (command != 'developer_echo') return null;
    return args.isEmpty ? '用法：/developer_echo 内容' : args.join(' ');
  }
}
