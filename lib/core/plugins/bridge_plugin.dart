import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/plugin.dart';
import '../../models/plugin_manifest.dart';

/// Generic outbox protocol for external Node/Python plugins. No Steam logic,
/// QQ credentials, or Agent state lives here.
class BridgePlugin extends BotPlugin {
  final PluginManifest definition;
  Timer? _timer;
  Future<void>? _polling;
  HttpClient? _client;
  bool _running = false;
  int _generation = 0;
  String _scope = '';
  String _receiptScope = '';
  String _lastError = '';
  final Map<String, Map<String, dynamic>> _receipts = {};
  void Function(String)? onError;

  BridgePlugin(super.info, this.definition);

  Map<String, dynamic> get bridgeConfig => {
    for (final key in [
      ...definition.http['send_config_keys'] as List? ?? [],
      ...definition.http['send_secret_keys'] as List? ?? [],
    ])
      key.toString(): info.config[key],
  };

  String get bridgeUrl => definition.http['url'] as String;
  String get bridgeToken =>
      info.config[definition.http['token_config']]?.toString() ?? '';
  Map<String, dynamic> get bridgeParameters => const {};
  Duration get bridgeTimeout => const Duration(seconds: 8);
  String bridgeFailure(Map<String, dynamic> response) =>
      '插件服务初始化失败，请检查服务依赖与配置。';
  String bridgeStatus(Map<String, dynamic> response) => '';
  bool get bridgeRunning => _running;

  Future<Map<String, dynamic>> requestService(
    String route,
    String appId, [
    Map<String, dynamic> data = const {},
  ]) async {
    final token = bridgeToken;
    if (token.isEmpty) {
      throw const PluginManifestException('请先导入服务生成的插件配置，或填写服务连接令牌。');
    }
    final client = _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    final base = bridgeUrl;
    final uri = Uri.parse('${base.replaceFirst(RegExp(r'/+$'), '')}/v1/$route');
    final request = await client
        .postUrl(uri)
        .timeout(const Duration(seconds: 4));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.write(
      jsonEncode({
        'app_id': appId,
        'config': bridgeConfig,
        ...bridgeParameters,
        ...data,
      }),
    );
    final response = await request.close().timeout(bridgeTimeout);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      if (bytes.length + chunk.length > 8 * 1024 * 1024) {
        throw const PluginManifestException('桥接服务返回内容超过 8 MB。');
      }
      bytes.add(chunk);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PluginManifestException(
        response.statusCode == 403
            ? '插件服务拒绝连接，请核对服务令牌。'
            : response.statusCode == 429
            ? '插件服务正忙，请稍后重试。'
            : '插件服务请求失败（HTTP ${response.statusCode}）。',
      );
    }
    final value = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('桥接响应格式无效。');
    }
    return value;
  }

  void reportServiceError(String value) {
    if (_lastError == value) return;
    _lastError = value;
    onError?.call(value);
  }

  @override
  Future<void> onEnable() async {
    await validateBridge();
    _running = true;
    _generation++;
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(
        milliseconds: definition.http['poll_interval_ms'] as int? ?? 1500,
      ),
      (_) {
        unawaited(onTick());
      },
    );
  }

  Future<void> validateBridge() async {
    definition.validateConfig(info.config, requireValues: true);
    if (bridgeToken.isEmpty) {
      throw const PluginManifestException('请先填写插件服务连接令牌。');
    }
  }

  @override
  Future<void> onTick() {
    final existing = _polling;
    if (existing != null) return existing;
    final task = _poll();
    _polling = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_polling, task)) _polling = null;
      }),
    );
    return task;
  }

  @override
  List<PluginCommand> get commands => [
    for (final command
        in definition.rules
            .where((r) => ['prefix', 'command'].contains(r.trigger.type))
            .map((r) => r.trigger.value.replaceFirst(RegExp(r'^[/#]'), ''))
            .toSet())
      PluginCommand(command, info.description),
  ];

  @override
  Future<void> onDisable() async {
    _running = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _client?.close(force: true);
    _client = null;
    final previous = _scope;
    _scope = '';
    if (previous.isNotEmpty) {
      try {
        await requestService(
          'deactivate',
          previous,
        ).timeout(const Duration(seconds: 1));
      } catch (_) {}
      _client?.close(force: true);
      _client = null;
    }
    await _polling;
    _receipts.clear();
    _receiptScope = '';
    _lastError = '';
  }

  Future<void> _poll() async {
    final runtime = host;
    if (!_running || runtime == null || !runtime.serviceReady()) return;
    final appId = runtime.currentAppId();
    if (appId.isEmpty) return;
    final generation = _generation;
    bool current() =>
        _running &&
        generation == _generation &&
        runtime.currentAppId() == appId &&
        runtime.serviceReady();
    try {
      if (_scope.isNotEmpty && _scope != appId) {
        await requestService('deactivate', _scope);
      }
      _scope = appId;
      if (_receiptScope != appId) {
        final saved = await runtime.store.read('bridge_receipts');
        if (!current()) return;
        for (final entry in saved.entries) {
          if (entry.value is Map && entry.value['ok'] is bool) {
            _receipts['$appId:${entry.key}'] = Map<String, dynamic>.from(
              entry.value,
            );
          }
        }
        _receiptScope = appId;
      }
      final response = await requestService('poll', appId);
      if (!current()) return;
      if (response['ok'] != true) {
        reportServiceError(bridgeFailure(response));
        return;
      }
      reportServiceError(bridgeStatus(response));
      final messages = response['messages'];
      if (messages is! List || messages.length > 1) {
        throw const FormatException('桥接队列格式无效。');
      }
      for (final value in messages) {
        if (!current()) return;
        if (value is! Map<String, dynamic> ||
            value['app_id'] != appId ||
            value['id'] is! String ||
            (value['id'] as String).length > 128) {
          throw const FormatException('桥接消息范围无效。');
        }
        final id = value['id'] as String;
        final receiptKey = '$appId:$id';
        final readOnly = value['action'] == 'members';
        final receipt =
            (!readOnly ? _receipts[receiptKey] : null) ??
            await runtime.serviceRequest(value);
        // Remember successful and failed platform results before ACK. A lost ACK
        // must never cause the same envelope to be sent to QQ again.
        if (!readOnly) _receipts[receiptKey] = receipt;
        while (_receipts.length > 512) {
          _receipts.remove(_receipts.keys.first);
        }
        if (!current()) return;
        if (!readOnly) {
          await runtime.store.update('bridge_receipts', (saved) {
            saved[id] = receipt;
            while (saved.length > 256) {
              saved.remove(saved.keys.first);
            }
          });
        }
        if (!current()) return;
        await requestService('ack', appId, {'id': id, 'result': receipt});
      }
    } catch (error) {
      if (current()) {
        reportServiceError(
          error is PluginManifestException
              ? error.message
              : '插件服务未连接，请启动服务并检查地址和令牌。',
        );
      }
    }
  }

  @override
  bool acceptsUnmentioned(PluginMessage message) => definition.rules.any(
    (r) =>
        r.trigger.matches(message) &&
        (!message.isFullGroupMessage ||
            message.isMentioned ||
            r.trigger.type == 'command' ||
            info.permissions.contains('events:group-all')),
  );

  @override
  Future<PluginReply?> execute(PluginMessage message) async {
    if (!_running ||
        message.eventType != 'message' ||
        !acceptsUnmentioned(message)) {
      return null;
    }
    final rule = definition.rules.firstWhere((r) => r.trigger.matches(message));
    if (rule.permission != 'all' &&
        message.senderRole != 'operator' &&
        message.senderRole != 'owner' &&
        !(rule.permission == 'admin' && message.senderRole == 'admin')) {
      return const PluginReply('此命令仅限群主或管理员使用。', format: 'text');
    }
    final appId = host?.appId ?? '';
    if (appId.isEmpty || message.messageId.isEmpty) {
      return const PluginReply('请先连接机器人并从 QQ 发送插件命令。', format: 'text');
    }
    try {
      final response = await requestService('message', appId, {
        'job_id': message.messageId,
        'message': message.toMap(),
      });
      if (response['ok'] != true) throw const FormatException('插件服务拒绝了消息。');
      return const PluginReply('', format: 'deferred');
    } catch (error) {
      return PluginReply(
        error is PluginManifestException ? error.message : '插件服务未连接，请检查本机服务。',
        format: 'text',
      );
    }
  }

  @override
  Future<void> updateConfig(Map<String, dynamic> newConfig) async {
    final restart = _running;
    if (restart) await onDisable();
    await super.updateConfig(newConfig);
    if (restart) await onEnable();
  }

  @override
  Future<String?> onCommand(String command, List<String> args) async => null;
  @override
  Future<String?> onMessage(PluginMessage message) async => null;
}
