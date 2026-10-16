import 'sdk.dart';

import 'dice_plugin/plugin.dart';
import 'example_plugin/plugin.dart';
import 'translate_comment/plugin.dart';
import 'weather_plugin/plugin.dart';
import 'daily_club/plugin.dart';
import 'group_games/plugin.dart';

/// 随应用编译的 Dart 工厂。清单和实际实现均放在 plugins/ 下。
/// 新增 Dart 插件时在这里注册，再添加 index.json 和 pubspec.yaml 资源。
class BuiltInPluginRegistry {
  static final Map<String, BotPlugin Function(PluginInfo)> factories = {
    'example_plugin': ExamplePlugin.new,
    'weather_plugin': WeatherPlugin.new,
    'dice_plugin': DicePlugin.new,
    'translate_comment': TranslateCommentPlugin.new,
    'daily_club': DailyClubPlugin.new,
    'group_games': GroupGamesPlugin.new,
  };

  static BotPlugin? create(String id, PluginInfo info) =>
      factories[id]?.call(info);
}
