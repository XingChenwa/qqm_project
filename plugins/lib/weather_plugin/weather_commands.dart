import '../src/commands.dart';

/// 仅匹配明确查询指令，不把日常聊天误判成天气请求。
class WeatherQuery {
  final bool isWeather;
  final String argument;
  final bool isForecast;
  final bool isCityCode;
  const WeatherQuery(
    this.isWeather,
    this.argument, {
    this.isForecast = false,
    this.isCityCode = false,
  });

  static const forecastCommands = {'天气预报', '预报', 'forecast'};
  static const cityCommands = {'城市编码', 'adcode'};

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
    '^(${[...forecastCommands, ...cityCommands, ...weatherCommands, ...ipCommands].map(RegExp.escape).join('|')})'
    r'(?:[ \t:：]+([^\r\n]*))?$',
    caseSensitive: false,
  );

  static WeatherQuery? fromCommand(String command, String argument) {
    final normalized = command.trim().toLowerCase();
    if (forecastCommands.contains(normalized)) {
      return WeatherQuery(true, argument.trim(), isForecast: true);
    }
    if (cityCommands.contains(normalized)) {
      return WeatherQuery(true, argument.trim(), isCityCode: true);
    }
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
