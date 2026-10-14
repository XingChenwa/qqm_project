import '../../models/plugin.dart';
import '../../services/amap_service.dart';

class WeatherPlugin extends BotPlugin {
  final AmapService _amap;
  WeatherPlugin(super.info, {AmapService? amapService})
    : _amap = amapService ?? AmapService();

  static const _weatherCommands = {
    'weather',
    'tianqi',
    '天气',
    '查询天气',
    '天气查询',
    '查天气',
  };
  static const _ipCommands = {
    'ip',
    '查ip',
    '查询ip',
    '查ip地址',
    '查询ip地址',
    'ip地址',
    'ip查询',
    'ip地址查询',
  };
  static const _weatherUsage =
      '用法：天气 北京 / 查询天气 上海 / /天气 深圳 / /weather 110105。\n只发送“查询天气”或“天气”时使用插件配置中的默认城市；未配置时请带上城市。';
  static const _ipUsage =
      '用法：查ip地址 114.114.114.114 / /ip 114.114.114.114。\n请提供要查询的国内 IPv4 地址；QQ 官方消息不提供发送者 IP，不能通过 QQ 号查询用户 IP。';

  @override
  Duration get executionTimeout => const Duration(seconds: 20);

  @override
  Future<void> onEnable() async {}

  @override
  Future<void> onDisable() async {}

  @override
  Future<String?> onMessage(PluginMessage message) async {
    // 只匹配完整指令，不截取普通聊天正文中的“天气”或“IP”。
    final match = RegExp(
      r'^(查询天气|天气查询|查天气|天气|weather|tianqi|查询ip地址|查ip地址|ip地址查询|查询ip|查ip|ip查询|ip地址|ip)(?:[ \t:：]+([^\r\n]*))?$',
      caseSensitive: false,
    ).firstMatch(message.content.trim());
    if (match == null) return null;
    return onCommand(match.group(1)!, [
      if ((match.group(2) ?? '').trim().isNotEmpty) match.group(2)!.trim(),
    ]);
  }

  @override
  Future<String?> onCommand(String command, List<String> args) async {
    final normalized = command.trim().toLowerCase();
    if (!_weatherCommands.contains(normalized) &&
        !_ipCommands.contains(normalized)) {
      return null;
    }
    final argument = args.join(' ').trim();
    final weather = _weatherCommands.contains(normalized);
    final city = argument.isNotEmpty
        ? argument
        : (info.config['default_city']?.toString().trim() ?? '');
    if (weather && city.isEmpty) return _weatherUsage;
    if (!weather && argument.isEmpty) return _ipUsage;
    final key = info.config['amap_key']?.toString().trim() ?? '';
    try {
      return weather
          ? _formatWeather(await _amap.weather(city, key), city)
          : _formatIp(await _amap.locateIp(argument, key), argument);
    } on AmapException catch (e) {
      return '${weather ? '天气' : 'IP'}查询失败：${e.message}';
    } catch (_) {
      return '${weather ? '天气' : 'IP'}查询失败：接口数据异常，请稍后重试。';
    }
  }

  String _formatWeather(Map<String, dynamic> data, String requestedCity) {
    final city = amapText(data['city']);
    final province = amapText(data['province']);
    final direction = amapText(data['winddirection']);
    final location = city.isEmpty
        ? requestedCity
        : (province.isNotEmpty && province != city ? '$province $city' : city);
    final wind = [
      if (direction.isNotEmpty)
        direction.endsWith('风') || direction.contains('风向')
            ? direction
            : '$direction风',
      if (amapText(data['windpower']).isNotEmpty)
        '${amapText(data['windpower'])}级',
    ].join(' ');
    return [
      '$location 实况天气',
      '天气：${_value(data['weather'])}',
      '温度：${_value(data['temperature'], unit: '℃')}',
      '湿度：${_value(data['humidity'], unit: '%')}',
      '风况：${wind.isEmpty ? '暂无数据' : wind}',
      '更新时间：${_value(data['reporttime'])}',
      '数据来源：高德地图',
    ].join('\n');
  }

  String _formatIp(Map<String, dynamic> data, String ip) {
    final province = amapText(data['province']);
    final city = amapText(data['city']);
    if (province.isEmpty && city.isEmpty) {
      return 'IP：$ip\n未查询到位置。高德基础 IP 接口仅支持国内 IPv4，不支持国外 IP 或 IPv6。';
    }
    final location = [
      if (province.isNotEmpty) province,
      if (city.isNotEmpty && city != province) city,
    ].join(' ');
    return [
      'IP：$ip',
      '归属地：$location',
      if (amapText(data['adcode']).isNotEmpty)
        '行政区编码：${amapText(data['adcode'])}',
      '数据来源：高德地图（IP 定位仅供参考，不代表用户的实时位置）',
    ].join('\n');
  }

  String _value(dynamic raw, {String unit = ''}) {
    final value = amapText(raw);
    return value.isEmpty ? '暂无数据' : '$value$unit';
  }
}
