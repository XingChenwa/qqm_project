import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/plugin.dart';
import '../../models/plugin_manifest.dart';
import '../../utils/helpers.dart';

class ManifestPlugin extends BotPlugin {
  final PluginManifest definition;
  ManifestPlugin(super.info, this.definition);

  @override
  Duration get executionTimeout => Duration(
    milliseconds: definition.runtime == 'http'
        ? (definition.http['timeout_ms'] as int? ?? 8000) + 1000
        : 1000,
  );

  @override
  Future<void> onEnable() async {
    definition.validateConfig(info.config, requireValues: true);
  }

  @override
  Future<void> onDisable() async {}

  @override
  Future<String?> handleMessage(PluginMessage message) async {
    final rule = definition.rules
        .where((r) => r.trigger.matches(message))
        .firstOrNull;
    if (rule == null) return null;
    if (definition.runtime == 'http') return _callService(message, rule);
    final variables = <String, String>{
      'content': message.content,
      'args': rule.trigger.arguments(message.content),
      'sender_name': message.senderName,
      'sender_id': message.senderId,
      'session_id': message.sessionId,
      'now': DateTime.now().toLocal().toIso8601String(),
      for (final field in definition.fields)
        if (field.type != 'secret')
          'config.${field.key}': info.config[field.key]?.toString() ?? '',
    };
    final reply = rule.reply.replaceAllMapped(
      RegExp(r'\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}'),
      (match) => variables[match.group(1)] ?? '',
    );
    if (reply.length > 16000) {
      throw const PluginManifestException('插件回复超过 16000 字符。');
    }
    return reply;
  }

  @override
  Future<String?> onMessage(PluginMessage message) => handleMessage(message);

  @override
  Future<String?> onCommand(String command, List<String> args) => handleMessage(
    PluginMessage(
      messageId: '',
      sessionId: '',
      senderId: '',
      senderName: '操作员',
      content: '/$command${args.isEmpty ? '' : ' ${args.join(' ')}'}',
      messageType: 0,
      isGroup: false,
      timestamp: DateTime.now(),
    ),
  );

  Future<String?> _callService(PluginMessage message, PluginRule rule) async {
    final settings = definition.http;
    final timeout = Duration(
      milliseconds: settings['timeout_ms'] as int? ?? 8000,
    );
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await (() async {
        final request = await client.postUrl(
          Uri.parse(settings['url'] as String),
        );
        // 不跟随重定向，避免将正文或插件授权令牌转交给另一个地址。
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        final tokenKey = settings['token_config'] as String?;
        final token = tokenKey == null
            ? ''
            : info.config[tokenKey]?.toString().trim() ?? '';
        if (token.codeUnits.any((c) => c < 33 || c > 126)) {
          throw const PluginManifestException('插件服务令牌格式无效。');
        }
        if (token.isNotEmpty) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        final command = parseSlashCommand(message.content);
        final body = utf8.encode(
          jsonEncode({
            'schema_version': 1,
            'plugin_id': info.id,
            'event': command == null ? 'message' : 'command',
            'command': command?.command,
            'args': command?.args ?? <String>[],
            'text': rule.trigger.arguments(message.content),
            'message': message.toMap(),
            'config': {
              for (final key in (settings['send_config_keys'] as List? ?? []))
                key as String: info.config[key],
            },
          }),
        );
        if (body.length > 64 * 1024) {
          throw const PluginManifestException('插件请求超过 64 KB，已跳过。');
        }
        request.contentLength = body.length;
        request.add(body);
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw PluginManifestException(
            '插件服务返回 HTTP ${response.statusCode}，未发送回复。',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 64 * 1024) {
            throw const PluginManifestException('插件响应超过 64 KB。');
          }
          bytes.addAll(chunk);
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map ||
            !decoded.containsKey('reply') ||
            decoded['reply'] != null && decoded['reply'] is! String) {
          throw const PluginManifestException(
            '插件响应必须是 {"reply":"文本"} 或 {"reply":null}。',
          );
        }
        final reply = decoded['reply'] as String?;
        if (reply != null && reply.length > 16000) {
          throw const PluginManifestException('插件回复超过 16000 字符。');
        }
        return reply;
      })().timeout(timeout);
    } on PluginManifestException {
      rethrow;
    } on TimeoutException {
      throw const PluginManifestException('插件服务请求超时。');
    } catch (_) {
      // 不显示原始请求、响应、URL 或 HttpClient 异常，避免泄露令牌。
      throw const PluginManifestException('插件服务连接失败或响应不是有效 JSON。');
    } finally {
      client.close(force: true);
    }
  }
}
