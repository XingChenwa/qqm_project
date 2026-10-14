import '../../models/plugin.dart';
import 'dice_plugin.dart';
import 'example_plugin.dart';
import 'translate_comment_plugin.dart';
import 'weather_plugin.dart';

class BuiltInPluginDefinition {
  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String directory;
  final bool enabledByDefault;
  final Map<String, dynamic> defaultConfig;
  final List<String> permissions;

  const BuiltInPluginDefinition({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    this.author = 'QQ 机器人管理器',
    this.directory = '',
    this.enabledByDefault = true,
    this.defaultConfig = const {},
    this.permissions = const [],
  });
}

class BuiltInPluginRegistry {
  static const definitions = <BuiltInPluginDefinition>[
    BuiltInPluginDefinition(
      id: 'example_plugin',
      name: '基础助手',
      version: '1.0.0',
      description: '提供问候、帮助和 ping 测试回复。',
      permissions: ['message:read', 'message:send'],
    ),
    BuiltInPluginDefinition(
      id: 'weather_plugin',
      name: '天气与 IP 查询',
      version: '1.1.0',
      description: '高德实况天气与 IP 定位：天气 北京、查询天气 上海、/天气 深圳、查ip地址 IPv4、/ip IPv4。',
      defaultConfig: {'amap_key': '', 'default_city': ''},
      permissions: ['message:read', 'message:send', 'network:amap'],
    ),
    BuiltInPluginDefinition(
      id: 'dice_plugin',
      name: '骰子插件',
      version: '1.0.0',
      description: '支持 /dice、/roll 和 2d6 这类骰子表达式。',
      permissions: ['message:read', 'message:send'],
    ),
    BuiltInPluginDefinition(
      id: 'translate_comment',
      name: '代码注释翻译',
      version: '1.0.0',
      description: '调用 DeepSeek 翻译代码块中的注释。',
      defaultConfig: {'target_lang': '中文'},
      permissions: ['message:read', 'message:send', 'network:deepseek'],
    ),
  ];

  static BotPlugin? create(String id, PluginInfo info) {
    return switch (id) {
      'example_plugin' => ExamplePlugin(info),
      'weather_plugin' => WeatherPlugin(info),
      'dice_plugin' => DicePlugin(info),
      'translate_comment' => TranslateCommentPlugin(info),
      _ => null,
    };
  }
}
