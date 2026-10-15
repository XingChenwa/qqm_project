import '../src/commands.dart';

/// 群聊免 @ 的窄范围白名单，与天气插件共用，避免放开所有自动回复。
class WeatherQuery {
  final bool isWeather;
  final String argument;
  const WeatherQuery(this.isWeather, this.argument);

  static const weatherCommands = {
    'weather',
    'tianqi',
    '天气',
    '查询天气',
    '天气查询',
    '查天气',
  };
  static const ipCommands = {
    'ip',
    '查ip',
    '查询ip',
    '查ip地址',
    '查询ip地址',
    'ip地址',
    'ip查询',
    'ip地址查询',
  };
  static final _plain = RegExp(
    '^(${[...weatherCommands, ...ipCommands].map(RegExp.escape).join('|')})'
    r'(?:[ \t:：]+([^\r\n]*))?$',
    caseSensitive: false,
  );

  static WeatherQuery? fromCommand(String command, String argument) {
    final normalized = command.trim().toLowerCase();
    if (weatherCommands.contains(normalized)) {
      return WeatherQuery(true, argument.trim());
    }
    if (ipCommands.contains(normalized)) {
      return WeatherQuery(false, argument.trim());
    }
    return null;
  }

  static WeatherQuery? parse(String text) {
    final slash = parseSlashCommand(text);
    if (slash != null) return fromCommand(slash.command, slash.args.join(' '));
    final match = _plain.firstMatch(text.trim());
    return match == null
        ? null
        : fromCommand(match.group(1)!, match.group(2) ?? '');
  }
}
