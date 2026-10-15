import 'dart:convert';

import 'package:dio/dio.dart';

/// 天气插件自带服务：只访问高德固定 HTTPS 接口，错误文本不会暴露 Key。
class AmapService {
  static const _baseUrl = 'https://restapi.amap.com';
  static const _requestTimeout = Duration(seconds: 8);
  final Dio _dio;
  final Map<String, ({String code, DateTime at})> _cityCodes = {};

  AmapService({Dio? dio})
    : _dio =
          dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));

  Future<Map<String, dynamic>> weather(String city, String key) async {
    _requireKey(key);
    final code = await _resolveCity(city.trim(), key);
    final data = await _get('/v3/weather/weatherInfo', key, {
      'city': code,
      'extensions': 'base',
    });
    final lives = data['lives'];
    if (lives is! List || lives.isEmpty || lives.first is! Map) {
      throw const AmapException('该地区暂无实况天气，请尝试附近城市或更准确的行政区编码。');
    }
    final live = Map<String, dynamic>.from(lives.first as Map);
    if (amapText(live['weather']).isEmpty &&
        amapText(live['temperature']).isEmpty) {
      throw const AmapException('接口没有返回有效的天气数据，请稍后再试。');
    }
    return live;
  }

  Future<Map<String, dynamic>> locateIp(String ip, String key) async {
    if (!isIpv4(ip)) {
      throw const AmapException(
        '请输入有效的 IPv4 地址，例如 114.114.114.114；高德基础接口不支持 IPv6。',
      );
    }
    _requireKey(key);
    return _get('/v3/ip', key, {'ip': ip});
  }

  Future<String> _resolveCity(String city, String key) async {
    if (city.isEmpty || city.length > 60 || city.contains('\n')) {
      throw const AmapException('请填写城市/区县名称或六位行政区编码，例如：天气 北京。');
    }
    if (RegExp(r'^\d{6}$').hasMatch(city)) return city;
    final cacheKey = '$key:$city';
    final cached = _cityCodes[cacheKey];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(hours: 24)) {
      return cached.code;
    }
    final data = await _get('/v3/config/district', key, {
      'keywords': city,
      'subdistrict': '0',
      'extensions': 'base',
      'page': '1',
      'offset': '20',
    });
    final raw = data['districts'];
    final districts = raw is List
        ? raw.whereType<Map>().map((d) => Map<String, dynamic>.from(d)).toList()
        : <Map<String, dynamic>>[];
    final candidates = <String, Map<String, dynamic>>{};
    for (final district in districts) {
      final code = amapText(district['adcode']);
      final level = amapText(district['level']);
      if (RegExp(r'^\d{6}$').hasMatch(code) &&
          (level == 'city' ||
              level == 'district' ||
              (level == 'province' &&
                  const [
                    '110000',
                    '120000',
                    '310000',
                    '500000',
                  ].contains(code)))) {
        candidates[code] = district;
      }
    }
    if (candidates.isEmpty) {
      throw AmapException(
        districts.isEmpty
            ? '未找到“$city”，请检查城市/区县名称，或直接使用六位行政区编码。'
            : '请指定具体城市/区县，不要使用整个省份作为天气查询区域。',
      );
    }
    // 不擅自选择同名地区；要求用户使用编码明确选择。
    final exact = candidates.values
        .where((d) => amapText(d['name']) == city)
        .toList();
    final selected = exact.isEmpty ? candidates.values.toList() : exact;
    final count = int.tryParse(amapText(data['count'])) ?? districts.length;
    if (selected.length != 1 || count > districts.length) {
      final choices = selected
          .take(5)
          .map((d) => '${amapText(d['name'])}（${amapText(d['adcode'])}）')
          .join('\n');
      throw AmapException(
        '找到多个地区，请使用行政区编码明确查询：\n$choices\n例如：天气 ${amapText(selected.first['adcode'])}',
      );
    }
    final code = amapText(selected.single['adcode']);
    if (_cityCodes.length >= 128) _cityCodes.remove(_cityCodes.keys.first);
    _cityCodes[cacheKey] = (code: code, at: DateTime.now());
    return code;
  }

  Future<Map<String, dynamic>> _get(
    String path,
    String key,
    Map<String, String> parameters,
  ) async {
    final cancel = CancelToken();
    try {
      final response = await _dio
          .get<dynamic>(
            '$_baseUrl$path',
            queryParameters: {
              'key': key.trim(),
              'output': 'JSON',
              ...parameters,
            },
            cancelToken: cancel,
            options: Options(
              responseType: ResponseType.json,
              receiveTimeout: _requestTimeout,
              sendTimeout: _requestTimeout,
              followRedirects: false,
              validateStatus: (_) => true,
            ),
          )
          .timeout(
            _requestTimeout,
            onTimeout: () {
              cancel.cancel('请求超时');
              throw const AmapException('高德接口响应超时，请稍后再试。');
            },
          );
      if ((response.statusCode ?? 0) < 200 ||
          (response.statusCode ?? 0) >= 300) {
        throw AmapException('高德接口 HTTP ${response.statusCode ?? 0}，请稍后再试。');
      }
      final raw = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (raw is! Map) throw const AmapException('高德接口返回格式异常，请稍后再试。');
      final data = Map<String, dynamic>.from(raw);
      final code = amapText(data['infocode']);
      if (data['status']?.toString() != '1' ||
          (code.isNotEmpty && code != '10000')) {
        throw AmapException(_errorText(code));
      }
      return data;
    } on DioException catch (e) {
      if (e.error is FormatException) {
        throw const AmapException('高德接口返回格式异常，请稍后再试。');
      }
      if (const [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ].contains(e.type)) {
        throw const AmapException('高德接口响应超时，请稍后再试。');
      }
      throw const AmapException('无法连接高德接口，请检查网络后重试。');
    } on FormatException {
      throw const AmapException('高德接口返回格式异常，请稍后再试。');
    }
  }

  static void _requireKey(String key) {
    if (key.trim().isEmpty) {
      throw const AmapException(
        '天气插件尚未配置高德 Web 服务 Key，请在“插件 → 天气与 IP 查询 → 配置”中填写。',
      );
    }
  }

  static String _errorText(String code) {
    final reason = switch (code) {
      '10001' || '10013' => '高德 Key 无效、过期或已删除，请检查插件配置',
      '10002' || '10012' || '10041' => '高德 Key 未开通此服务或权限已过期，请检查高德控制台',
      '10003' || '10044' => '高德今日查询额度已用完，请检查账号配额',
      '10004' ||
      '10014' ||
      '10015' ||
      '10019' ||
      '10020' ||
      '10021' => '高德查询过于频繁，请稍后重试',
      '10005' || '10010' => '高德出口 IP 白名单或 IP 访问额度限制，请检查高德控制台',
      '10007' => '此 Key 要求数字签名；当前插件仅支持普通 Web 服务 Key，请调整 Key 鉴权方式',
      '10009' => 'Key 类型不匹配，请使用“Web 服务”类型，而不是 JS/Android/iOS Key',
      '20000' || '20001' => '查询参数无效，请检查城市编码或 IPv4 地址',
      '40000' || '40002' => '高德服务余额不足或服务已到期，请检查高德控制台',
      _ => '高德服务暂时不可用，请稍后重试或检查控制台',
    };
    final safeCode = RegExp(r'^\d{5}$').hasMatch(code) ? code : '未知';
    return '$reason（错误码：$safeCode）。';
  }
}

/// 高德的无结果字段可能是 []，不能直接 toString() 显示给用户。
String amapText(dynamic value) =>
    value is String ? value.trim() : (value is num ? value.toString() : '');

bool isIpv4(String value) {
  final parts = value.split('.');
  return parts.length == 4 &&
      parts.every(
        (part) =>
            RegExp(r'^(0|[1-9]\d{0,2})$').hasMatch(part) &&
            (int.tryParse(part) ?? 256) <= 255,
      );
}

class AmapException implements Exception {
  final String message;
  const AmapException(this.message);
  @override
  String toString() => message;
}
