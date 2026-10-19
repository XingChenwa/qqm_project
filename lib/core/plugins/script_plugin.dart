import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/plugin.dart';
import '../../models/plugin_manifest.dart';
import 'script_runner.dart';

/// The same loader and capabilities for shipped and third-party scripts.
class ScriptPlugin extends BotPlugin {
  final PluginManifest definition;
  final Future<dynamic> Function(Map<String, dynamic>)? networkForTesting;
  late PluginScriptRunner _runner;
  final PluginScriptRunner Function() _runnerFactory;
  final _clients = <HttpClient>{};
  int _generation = 0;
  ScriptPlugin(
    super.info,
    this.definition, {
    this.networkForTesting,
    PluginScriptRunner Function()? runnerFactory,
  }) : _runnerFactory = runnerFactory ?? PluginScriptRunner.new {
    _runner = _runnerFactory();
  }
  Map<String, dynamic> get script =>
      Map<String, dynamic>.from(definition.data['script']);
  @override
  Duration get executionTimeout =>
      Duration(milliseconds: (script['timeout_ms'] as int? ?? 3000) + 5000);
  @override
  List<PluginCommand> get commands => [
    for (final command in script['commands'] as List? ?? [])
      PluginCommand(
        command['name'],
        command['description'],
        usage: command['usage'] ?? '',
        aliases: List<String>.from(command['aliases'] ?? []),
      ),
  ];
  @override
  bool acceptsUnmentioned(PluginMessage message) {
    final options = script['unmentioned'] as Map? ?? {};
    if (options['commands'] != false &&
        parseSlashCommand(message.content) != null) {
      return true;
    }
    final text = message.content.trim().toLowerCase();
    return (options['prefixes'] as List? ?? []).any(
      (prefix) => text.startsWith((prefix as String).toLowerCase()),
    );
  }

  @override
  Future<void> onEnable() async {
    definition.validateConfig(info.config, requireValues: true);
    if (script['source'] is! String) {
      throw const PluginManifestException('缺少脚本源码，请从工作台安装完整项目。');
    }
    _runner.close();
    _runner = _runnerFactory();
    _generation++;
    await _run(null, {}, phase: 'enable');
  }

  @override
  Future<void> onDisable() async {
    _generation++;
    _runner.close();
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }

  @override
  Future<String?> onMessage(PluginMessage message) async => null;
  @override
  Future<String?> onCommand(String command, List<String> args) async => null;
  @override
  Future<PluginReply?> execute(PluginMessage message) async {
    if (message.eventType == 'interaction' &&
        !info.permissions.contains('interaction:read')) {
      return null;
    }
    if (!info.permissions.contains('storage:local') || host == null) {
      return _run(message, {});
    }
    final generation = _generation;
    final key = jsonEncode([
      message.isGroup ? 'group' : 'private',
      message.sessionId,
    ]);
    return host!.store.update<PluginReply?>(key, (state) async {
      if (generation != _generation) return null;
      return _run(message, state);
    });
  }

  Future<PluginReply?> _run(
    PluginMessage? message,
    Map<String, dynamic> state, {
    String phase = 'message',
  }) async {
    final generation = _generation;
    final clients = <HttpClient>{};
    final parsed = parseSlashCommand(message?.content ?? '');
    final now = DateTime.now(),
        beijing = DateTime.now().toUtc().add(const Duration(hours: 8));
    try {
      final result = await _runner.run(
        script['source'] as String,
        {
          'phase': phase,
          'id': info.id,
          'app_id': host?.appId ?? '',
          'message': message?.toMap() ?? {},
          'config': info.config,
          'state': state,
          'command': parsed?.command ?? '',
          'args': parsed?.args ?? [],
          'text': message?.content ?? '',
          'help': host?.help() ?? '',
          'now': now.millisecondsSinceEpoch,
          'beijing': beijing.toString().substring(0, 19),
          'today': beijing.toIso8601String().substring(0, 10),
          'yesterday': beijing
              .subtract(const Duration(days: 1))
              .toIso8601String()
              .substring(0, 10),
        },
        timeout: Duration(milliseconds: script['timeout_ms'] as int? ?? 3000),
        http: phase == 'enable' ? null : (request) => _http(request, clients),
      );
      if (generation != _generation) throw StateError('插件已停用，本次结果已丢弃');
      final value = result['result'];
      if (value is Map && value['error'] is String) {
        throw StateError(value['error']);
      }
      PluginReply? reply;
      if (phase != 'enable' && value != null) {
        if (value is String && value.length > 16000) {
          throw const FormatException('回复文本超过 16000 字符');
        }
        reply = value is String
            ? PluginReply(value)
            : PluginReply.fromMap(Map<String, dynamic>.from(value as Map));
        if (reply.format == 'media' &&
            (!info.permissions.contains('message:media') ||
                !(definition.data['media_hosts'] as List? ?? []).contains(
                  Uri.parse(reply.mediaUrl).host,
                ))) {
          throw const FormatException('媒体回复未声明对应权限和域名');
        }
        if (reply.buttons
            .expand((row) => row)
            .any(
              (button) =>
                  button.callback &&
                  (!info.permissions.contains('interaction:read') ||
                      !button.data.startsWith('qqm:${info.id}:')),
            )) {
          throw const FormatException('回调按钮未声明权限或使用了其他插件命名空间');
        }
      }
      if (phase != 'enable' && info.permissions.contains('storage:local')) {
        final next = Map<String, dynamic>.from(result['state'] as Map);
        state
          ..clear()
          ..addAll(next);
      }
      return reply;
    } catch (error) {
      var detail = error is StateError
          ? error.message.toString()
          : '脚本返回值或配置无效';
      for (final key in definition.secretKeys) {
        final secret = info.config[key]?.toString() ?? '';
        if (secret.isNotEmpty) detail = detail.replaceAll(secret, '[密钥已隐藏]');
      }
      throw PluginManifestException(
        detail.substring(0, detail.length.clamp(0, 300)),
      );
    } finally {
      for (final client in clients) {
        client.close(force: true);
        _clients.remove(client);
      }
    }
  }

  Future<dynamic> _http(
    Map<String, dynamic> request,
    Set<HttpClient> clients,
  ) async {
    final url = Uri.tryParse(request['url']?.toString() ?? '');
    if (!info.permissions.contains('network:http') ||
        url == null ||
        url.scheme != 'https' ||
        url.port != 443 ||
        url.userInfo.isNotEmpty ||
        url.hasFragment ||
        !(script['hosts'] as List? ?? []).contains(url.host)) {
      throw StateError('未授权网络地址');
    }
    final method = request['method'] ?? 'GET';
    if (!['GET', 'POST'].contains(method)) throw StateError('只允许 GET/POST');
    if (networkForTesting != null) return networkForTesting!(request);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final addresses = await InternetAddress.lookup(uri.host);
      if (addresses.isEmpty || addresses.any((address) => !_public(address))) {
        throw StateError('拒绝访问本机或内网');
      }
      return Socket.startConnect(addresses.first, uri.port);
    };
    _clients.add(client);
    clients.add(client);
    try {
      final call = await client.openUrl(method as String, url);
      call.followRedirects = false;
      final headers = request['headers'] as Map? ?? {};
      for (final entry in headers.entries) {
        if (![
              'authorization',
              'content-type',
              'accept',
            ].contains(entry.key.toString().toLowerCase()) ||
            entry.value is! String ||
            (entry.value as String).contains(RegExp(r'[\r\n]'))) {
          throw StateError('请求头无效');
        }
        call.headers.set(entry.key.toString(), entry.value);
      }
      if (method == 'POST') {
        call.headers.contentType = ContentType.json;
        final body = jsonEncode(request['body']);
        if (utf8.encode(body).length > 65536) throw StateError('请求体过大');
        call.write(body);
      }
      final response = await call.close().timeout(const Duration(seconds: 35));
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        if (bytes.length + chunk.length > 131072) {
          throw StateError('响应超过 128 KB');
        }
        bytes.addAll(chunk);
      }
      dynamic data;
      try {
        data = jsonDecode(utf8.decode(bytes));
      } catch (_) {
        data = null;
      }
      return {'status': response.statusCode, 'data': data};
    } finally {
      client.close(force: true);
      _clients.remove(client);
      clients.remove(client);
    }
  }

  static bool _public(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv6) {
      return bytes[0] >= 0x20 &&
          bytes[0] <= 0x3f &&
          !(bytes[0] == 0x20 &&
              bytes[1] == 0x01 &&
              bytes[2] == 0x0d &&
              bytes[3] == 0xb8);
    }
    final a = bytes[0], b = bytes[1];
    return a != 0 &&
        a != 10 &&
        a != 127 &&
        a < 224 &&
        !(a == 100 && b >= 64 && b <= 127) &&
        !(a == 169 && b == 254) &&
        !(a == 172 && b >= 16 && b <= 31) &&
        !(a == 192 && (b == 0 || b == 168)) &&
        !(a == 198 && (b == 18 || b == 19 || b == 51)) &&
        !(a == 203 && b == 0);
  }
}
