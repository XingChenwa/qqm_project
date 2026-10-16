import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'plugin.dart';

class PluginManifestException implements Exception {
  final String message;
  const PluginManifestException(this.message);
  @override
  String toString() => message;
}

class PluginConfigField {
  final String key;
  final String label;
  final String type;
  final dynamic defaultValue;
  final bool required;
  const PluginConfigField({
    required this.key,
    required this.label,
    required this.type,
    this.defaultValue,
    this.required = false,
  });

  bool accepts(dynamic value) => switch (type) {
    'boolean' => value is bool,
    'integer' => value is int,
    _ => value is String && value.length <= 8192,
  };
}

class PluginTrigger {
  final String type;
  final String value;
  final String scope;
  final bool caseSensitive;
  const PluginTrigger(this.type, this.value, this.scope, this.caseSensitive);

  bool matches(PluginMessage message) {
    if (scope == 'group' && !message.isGroup ||
        scope == 'private' && message.isGroup) {
      return false;
    }
    final text = message.content.trim();
    final actual = caseSensitive ? text : text.toLowerCase();
    final expected = caseSensitive ? value : value.toLowerCase();
    return switch (type) {
      'callback' =>
        message.eventType == 'interaction' &&
            message.callbackData.split(':').skip(2).firstOrNull == value,
      'command' => parseSlashCommand(text)?.command == value.toLowerCase(),
      'exact' => actual == expected,
      'prefix' => actual.startsWith(expected),
      'contains' => actual.contains(expected),
      _ => false,
    };
  }

  String arguments(String text) => switch (type) {
    'command' => parseSlashCommand(text)?.args.join(' ') ?? '',
    'prefix' => text.trim().substring(value.length).trimLeft(),
    'contains' => text,
    _ => '',
  };
}

class PluginRule {
  final PluginTrigger trigger;
  final String reply;
  final PluginReply? message;
  final String permission;
  const PluginRule(
    this.trigger,
    this.reply, {
    this.message,
    this.permission = 'all',
  });
}

/// v1/v2 清单是数据，不 eval、不启动进程，也不把导入的 Dart 当脚本执行。
class PluginManifest {
  static const maxBytes = 256 * 1024;
  final Map<String, dynamic> data;
  final List<PluginConfigField> fields;
  final List<PluginRule> rules;
  PluginManifest._(this.data, this.fields, this.rules);

  String get id => data['id'] as String;
  String get name => data['name'] as String;
  String get runtime => data['runtime'] as String;
  bool get isBundled => runtime == 'builtin';
  List<String> get permissions => List<String>.from(data['permissions']);
  Map<String, dynamic> get http =>
      Map<String, dynamic>.from(data['http'] ?? {});
  Set<String> get secretKeys => {
    for (final field in fields)
      if (field.type == 'secret') field.key,
  };
  Map<String, dynamic> get defaults => {
    for (final field in fields) field.key: field.defaultValue,
    ...Map<String, dynamic>.from(data['config'] ?? {}),
  };

  static PluginManifest parse(String source, {bool allowBuiltin = false}) {
    if (utf8.encode(source).length > maxBytes) {
      throw const PluginManifestException('插件清单不能超过 256 KB。');
    }
    dynamic decoded;
    try {
      decoded = source.trimLeft().startsWith('{')
          ? jsonDecode(source)
          : loadYaml(source);
      var nodes = 0;
      dynamic normalize(dynamic value, int depth) {
        if (++nodes > 10000 || depth > 16) {
          throw const PluginManifestException('插件清单嵌套过深或节点过多。');
        }
        if (value is Map) {
          final result = <String, dynamic>{};
          for (final entry in value.entries) {
            if (entry.key is! String) {
              throw const PluginManifestException('清单字段名必须是字符串。');
            }
            result[entry.key as String] = normalize(entry.value, depth + 1);
          }
          return result;
        }
        if (value is List) {
          return value.map((item) => normalize(item, depth + 1)).toList();
        }
        if (value == null || value is String || value is bool || value is num) {
          return value;
        }
        throw const PluginManifestException('清单包含不支持的数据类型。');
      }

      decoded = normalize(decoded, 0);
    } on PluginManifestException {
      rethrow;
    } catch (_) {
      throw const PluginManifestException('无法解析 JSON/YAML，请检查语法和缩进。');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const PluginManifestException('插件清单最外层必须是对象。');
    }
    final data = decoded;
    Never invalid(String message) => throw PluginManifestException(message);
    const knownFields = {
      r'$schema',
      'schema_version',
      'id',
      'name',
      'version',
      'description',
      'author',
      'runtime',
      'entrypoint',
      'permissions',
      'config',
      'config_schema',
      'rules',
      'http',
      'listen_all',
      'priority',
      'cooldown_ms',
      'media_hosts',
    };
    if (data.keys.any((key) => !knownFields.contains(key))) {
      invalid('清单包含未知字段，请对照 v2 协议检查拼写。');
    }
    if (data[r'$schema'] != null &&
        (data[r'$schema'] is! String ||
            (data[r'$schema'] as String).length > 512)) {
      invalid(r'$schema 必须是有效文本。');
    }
    if (![1, 2].contains(data['schema_version'])) {
      invalid('不支持的 schema_version，请使用 1 或 2。');
    }
    if (data['listen_all'] != null && data['listen_all'] is! bool ||
        data['priority'] != null &&
            (data['priority'] is! int ||
                data['priority'] < 0 ||
                data['priority'] > 1000) ||
        data['cooldown_ms'] != null &&
            (data['cooldown_ms'] is! int ||
                data['cooldown_ms'] < 0 ||
                data['cooldown_ms'] > 60000)) {
      invalid('监听选项、优先级或冷却时间无效。');
    }
    if (data['id'] is! String ||
        !RegExp(r'^[a-z][a-z0-9_]{2,63}$').hasMatch(data['id'])) {
      invalid('插件 ID 需为 3–64 位小写字母、数字和下划线，且以字母开头。');
    }
    for (final key in ['name', 'version', 'description']) {
      if (data[key] is! String ||
          (data[key] as String).trim().isEmpty ||
          (data[key] as String).length > (key == 'description' ? 1000 : 80)) {
        invalid('$key 必须填写有效文本。');
      }
    }
    if (data['author'] != null &&
        (data['author'] is! String ||
            (data['author'] as String).length > 120)) {
      invalid('author 必须是文本。');
    }
    final runtime = data['runtime'];
    if (runtime != 'builtin' && data.containsKey('entrypoint') ||
        runtime == 'rules' && data.containsKey('http')) {
      invalid('规则/HTTP 插件不使用 Dart 入口；规则插件也不使用 http 字段。');
    }
    if (!['rules', 'http', if (allowBuiltin) 'builtin'].contains(runtime)) {
      invalid('导入插件仅支持 rules 或 http；Dart 插件需要随应用编译。');
    }
    final permissions = data['permissions'];
    if (permissions is! List || permissions.any((p) => p is! String)) {
      invalid('permissions 必须是权限名称数组。');
    }
    if (!permissions.contains('message:read') ||
        !permissions.contains('message:send')) {
      invalid('插件必须声明 message:read 和 message:send。');
    }
    final allowed = {
      'message:read',
      'message:send',
      'message:media',
      'interaction:read',
      'events:group-all',
      if (runtime == 'http') 'network:http',
      if (allowBuiltin && runtime == 'builtin') ...[
        'network:amap',
        'network:deepseek',
      ],
    };
    if (permissions.any((p) => !allowed.contains(p)) ||
        permissions.toSet().length != permissions.length) {
      invalid('存在未支持或重复的权限。');
    }
    if (runtime == 'http' && !permissions.contains('network:http')) {
      invalid('HTTP 插件必须声明 network:http。');
    }
    if (data['listen_all'] == true &&
        !permissions.contains('events:group-all')) {
      invalid('监听未 @ 的普通聊天需要 events:group-all 权限。');
    }
    final mediaHosts = data['media_hosts'] ?? [];
    if (mediaHosts is! List ||
        mediaHosts.length > 8 ||
        mediaHosts.any(
          (host) =>
              host is! String ||
              !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9.-]{1,252}$').hasMatch(host) ||
              host.toLowerCase() == 'localhost' ||
              host.contains('..') ||
              RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host),
        )) {
      invalid('media_hosts 最多声明 8 个媒体域名，不能使用 IP 或本机地址。');
    }
    final rawFields = data['config_schema'] ?? [];
    if (rawFields is! List || rawFields.length > 32) invalid('配置项最多为 32 个。');
    final fields = <PluginConfigField>[];
    for (final raw in rawFields) {
      if (raw is Map &&
          raw.keys.any(
            (key) =>
                !['key', 'label', 'type', 'default', 'required'].contains(key),
          )) {
        invalid('config_schema 包含未知字段。');
      }
      if (raw is! Map<String, dynamic> ||
          raw['key'] is! String ||
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,63}$').hasMatch(raw['key']) ||
          fields.any((f) => f.key == raw['key']) ||
          raw['label'] is! String ||
          (raw['label'] as String).trim().isEmpty ||
          (raw['label'] as String).length > 80 ||
          !['string', 'secret', 'boolean', 'integer'].contains(raw['type'])) {
        invalid('config_schema 包含无效或重复的配置项。');
      }
      if (raw['required'] != null && raw['required'] is! bool) {
        invalid('required 必须是布尔值。');
      }
      final type = raw['type'] as String;
      final field = PluginConfigField(
        key: raw['key'],
        label: raw['label'],
        type: type,
        required: raw['required'] == true,
        defaultValue:
            raw['default'] ??
            (type == 'boolean'
                ? false
                : type == 'integer'
                ? 0
                : ''),
      );
      if (!field.accepts(field.defaultValue)) {
        invalid('配置项 ${field.key} 的默认值类型不匹配。');
      }
      fields.add(field);
    }
    final config = data['config'] ?? <String, dynamic>{};
    if (config is! Map<String, dynamic>) invalid('config 必须是对象。');
    for (final key in config.keys) {
      final field = fields.where((f) => f.key == key).firstOrNull;
      if (field == null || !field.accepts(config[key])) {
        invalid('配置项 $key 未声明或类型不匹配。');
      }
    }
    final rawRules = data['rules'] ?? [];
    if (rawRules is! List ||
        rawRules.length > 64 ||
        runtime != 'builtin' && rawRules.isEmpty) {
      invalid('rules 必须包含 1–64 条触发规则。');
    }
    final rules = <PluginRule>[];
    for (final raw in rawRules) {
      if (raw is! Map<String, dynamic> ||
          raw['match'] is! Map<String, dynamic>) {
        invalid('每条规则需要 match。');
      }
      final match = raw['match'] as Map<String, dynamic>;
      if (raw.keys.any(
            (key) => !['match', 'reply', 'message', 'permission'].contains(key),
          ) ||
          match.keys.any(
            (key) =>
                !['type', 'value', 'scope', 'case_sensitive'].contains(key),
          )) {
        invalid('规则包含未知字段。');
      }
      final type = match['type'];
      final value = match['value'];
      if (![
            'command',
            'exact',
            'prefix',
            'contains',
            'callback',
          ].contains(type) ||
          value is! String ||
          value.trim().isEmpty ||
          value.length > 256) {
        invalid('规则匹配类型或文本无效。');
      }
      if (type == 'command' && RegExp(r'[\s/#]').hasMatch(value)) {
        invalid('command 名称不要带 / 或空格。');
      }
      final scope = match['scope'] ?? 'all';
      if (!['all', 'group', 'private'].contains(scope)) {
        invalid('scope 只能为 all、group 或 private。');
      }
      if (match['case_sensitive'] != null && match['case_sensitive'] is! bool) {
        invalid('case_sensitive 必须是布尔值。');
      }
      if (raw.containsKey('reply') && raw.containsKey('message')) {
        invalid('reply 与 message 不能同时填写。');
      }
      final permission = raw['permission'] ?? 'all';
      if (!['all', 'admin', 'owner'].contains(permission)) {
        invalid('规则权限只能为 all、admin、owner。');
      }
      if (type == 'callback' && !permissions.contains('interaction:read')) {
        invalid('回调规则需要 interaction:read。');
      }
      PluginReply? structured;
      if (raw['message'] != null) {
        if (raw['message'] is! Map<String, dynamic>) invalid('message 必须为对象。');
        try {
          structured = PluginReply.fromMap(raw['message']);
        } on FormatException catch (error) {
          invalid(error.message);
        }
        if (structured.format == 'media' &&
            (!permissions.contains('message:media') ||
                !mediaHosts.contains(Uri.parse(structured.mediaUrl).host))) {
          invalid('媒体消息需要 message:media 权限与匹配的 media_hosts 域名。');
        }
      }
      final reply = raw['reply'] ?? '';
      if (reply is! String ||
          reply.length > 16000 ||
          runtime == 'rules' && reply.trim().isEmpty && structured == null) {
        invalid('规则插件的 reply 必须为 1–16000 字符文本。');
      }
      rules.add(
        PluginRule(
          PluginTrigger(type, value, scope, match['case_sensitive'] == true),
          reply,
          message: structured,
          permission: permission,
        ),
      );
    }
    if (runtime == 'http') {
      final http = data['http'];
      if (http is! Map<String, dynamic> || http['url'] is! String) {
        invalid('HTTP 插件需要 http.url。');
      }
      if (http.keys.any(
        (key) => ![
          'url',
          'timeout_ms',
          'token_config',
          'send_config_keys',
        ].contains(key),
      )) {
        invalid('http 包含未知字段。');
      }
      final uri = Uri.tryParse(http['url']);
      final loopback =
          uri != null &&
          ['localhost', '127.0.0.1', '::1', '[::1]'].contains(uri.host);
      if (uri == null ||
          uri.host.isEmpty ||
          uri.scheme != 'https' && !(uri.scheme == 'http' && loopback) ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        invalid('HTTP 地址必须是 HTTPS（本机调试可用回环 HTTP），不能含凭据、查询参数或片段。');
      }
      final timeout = http['timeout_ms'] ?? 8000;
      if (timeout is! int || timeout < 1000 || timeout > 20000) {
        invalid('HTTP 超时必须为 1000–20000 毫秒。');
      }
      final tokenKey = http['token_config'];
      if (tokenKey != null &&
          !fields.any((f) => f.key == tokenKey && f.type == 'secret')) {
        invalid('token_config 必须指向 secret 类型配置项。');
      }
      final sentKeys = http['send_config_keys'] ?? [];
      if (sentKeys is! List ||
          sentKeys.any(
            (key) => !fields.any((f) => f.key == key && f.type != 'secret'),
          )) {
        invalid('send_config_keys 只能包含已声明的非密钥配置项。');
      }
    }
    return PluginManifest._(data, fields, rules);
  }

  Map<String, dynamic> validateConfig(
    Map<String, dynamic> values, {
    bool requireValues = false,
  }) {
    final result = {...defaults, ...values};
    for (final field in fields) {
      final value = result[field.key];
      if (!field.accepts(value)) {
        throw PluginManifestException('配置项“${field.label}”的类型不正确。');
      }
      if (requireValues &&
          field.required &&
          value is String &&
          value.trim().isEmpty) {
        throw PluginManifestException('请先填写“${field.label}”。');
      }
    }
    return result;
  }

  PluginInfo toInfo({PluginInfo? saved, bool enabledByDefault = false}) =>
      PluginInfo(
        id: id,
        name: name,
        version: data['version'],
        description: data['description'],
        author: data['author'] ?? '',
        directory: 'plugins/$id',
        isEnabled: saved?.isEnabled ?? enabledByDefault,
        config: validateConfig(saved?.config ?? {}),
        permissions: permissions,
        manifest: jsonDecode(jsonEncode(data)) as Map<String, dynamic>,
      );

  /// 可分享的定义不携带本机配置，且主动清空清单中的密钥默认值。
  String exportDefinition() {
    final exported = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
    final config = exported['config'] as Map?;
    for (final key in secretKeys) {
      if (config?.containsKey(key) == true) config![key] = '';
    }
    for (final field in (exported['config_schema'] as List? ?? [])) {
      if (field['type'] == 'secret') field['default'] = '';
    }
    return const JsonEncoder.withIndent('  ').convert(exported);
  }
}
