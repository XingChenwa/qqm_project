import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:yaml/yaml.dart';
import 'models.dart';
import 'http.dart';
import 'script.dart';
import 'js_packages.dart';
import 'package_bundle.dart';
import 'redaction.dart';

class AgentExtension {
  final Json manifest;
  final bool enabled;
  final Map<String, String> secrets;
  final Json settings;
  AgentExtension(
    this.manifest, {
    this.enabled = false,
    this.secrets = const {},
    this.settings = const {},
  });
  String get id => text(manifest['id']);
  String get name => text(manifest['name']);
  String get kind => text(manifest['kind']);
  bool get isJavaScript => manifest['runtime'] == 'qq-agent-js';
  Json get packageManifest => object(manifest['packageManifest']);
  Json get config => {...object(packageManifest['settings']), ...settings};
  Json get configSchema => object(packageManifest['configSchema']);
  Iterable<String> get privateSettingValues => config.entries
      .where(
        (e) =>
            e.value is String &&
            (object(configSchema[e.key])['secret'] == true ||
                RegExp(
                  r'token|password|secret|api.?key|cookie',
                  caseSensitive: false,
                ).hasMatch(e.key)),
      )
      .map((e) => e.value as String)
      .where((v) => v.isNotEmpty);
  Json get compatibility => object(manifest['compatibility']);
  String get compatibilityLabel => switch (compatibility['state']) {
    'ready' => '导入检查通过',
    'partial' => '部分能力可用',
    'blocked' =>
      object(compatibility['availability'])['ok'] == false
          ? '缺少运行环境或配置'
          : '需要宿主适配',
    _ => '尚未检查兼容情况',
  };
  List<String> get compatibilityDetails => [
    ...strings(compatibility['blockers']),
    ...strings(compatibility['warnings']),
  ];
  String get prompt => isJavaScript
      ? (object(packageManifest['prompt'])['sections'] as List? ?? [])
            .map((v) => text(object(v)['content']))
            .where((v) => v.isNotEmpty)
            .join('\n\n')
      : text(manifest['prompt']);
  List<Json> get tools =>
      (manifest['tools'] as List? ?? []).map(object).toList();
  List<Json> get commands =>
      (manifest['commands'] as List? ?? []).map(object).toList();
  List<String> get origins => strings(manifest['allowedOrigins']);
  Json toJson({bool includeSecrets = true, bool includeFiles = true}) => {
    'manifest': includeFiles ? manifest : ({...manifest}..remove('files')),
    if (!includeFiles && isJavaScript)
      'fileNames': object(manifest['files']).keys.toList(),
    'enabled': enabled,
    'settings': settings,
    if (includeSecrets) 'secrets': secrets,
    'secretNames': secrets.keys.toList(),
  };
  factory AgentExtension.fromJson(Json j) => AgentExtension(
    object(j['manifest']),
    enabled: j['enabled'] == true,
    secrets: object(j['secrets']).map((k, v) => MapEntry(k, text(v))),
    settings: object(j['settings']),
  );
  AgentExtension copyWith({
    Json? manifest,
    bool? enabled,
    Json? settings,
    Map<String, String>? secrets,
  }) => AgentExtension(
    manifest ?? this.manifest,
    enabled: enabled ?? this.enabled,
    settings: settings ?? this.settings,
    secrets: secrets ?? this.secrets,
  );
  static AgentExtension fromPackage(List<int> bytes) =>
      AgentExtension(AgentPackageBundle.decode(bytes).normalized());

  /// Installation never trusts an enabled flag or embedded secret in a bundle.
  static AgentExtension parse(String source, {String filename = ''}) {
    if (source.length > 262144) throw const AgentException('扩展文件不能超过 256 KB。');
    try {
      Json manifest;
      if (filename.toLowerCase().endsWith('.md')) {
        final normalized = source.replaceAll('\r\n', '\n');
        final match = RegExp(
          r'^---\n([\s\S]*?)\n---\n([\s\S]*)$',
        ).firstMatch(normalized);
        if (match == null) {
          throw const AgentException(
            'SKILL.md 需要 YAML 元数据头（id、name、description）。',
          );
        }
        final header = object(jsonDecode(jsonEncode(loadYaml(match[1]!))));
        manifest = {
          'schema': 1,
          'id': header['id'] ?? header['name'],
          'name': header['name'],
          'description': header['description'],
          'kind': 'skill',
          'prompt': match[2]!,
          'tools': [],
        };
      } else {
        manifest = object(jsonDecode(jsonEncode(loadYaml(source))));
      }
      manifest.remove('enabled');
      manifest.remove('secrets');
      final result = AgentExtension(manifest);
      result.validate();
      return result;
    } on AgentException {
      rethrow;
    } catch (_) {
      throw const AgentException('扩展格式无效，请使用 Agent JSON / YAML 清单或 SKILL.md。');
    }
  }

  void validate() {
    if (manifest['schema'] != 1 ||
        !safeId(id) ||
        name.isEmpty ||
        name.length > 100 ||
        !{'plugin', 'skill'}.contains(kind) ||
        prompt.length > 16000) {
      throw const AgentException(
        '扩展必须包含 schema: 1、id、name 和 kind（plugin / skill）。',
      );
    }
    if (commands.length > 20 ||
        tools.length > 12 ||
        kind == 'plugin' &&
            !isJavaScript &&
            (commands.isEmpty || tools.isNotEmpty) ||
        kind == 'skill' && commands.isNotEmpty) {
      throw const AgentException(
        '命令插件需要 commands；Skill 使用 prompt / tools，每个 Skill 最多 12 个工具。',
      );
    }
    if (isJavaScript) {
      if (packageManifest['apiVersion'] != 1 ||
          packageManifest['id'] != id ||
          object(manifest['files']).isEmpty ||
          object(manifest['files']).length > 300 ||
          jsonEncode(manifest).length > 34 * 1024 * 1024 ||
          jsonEncode(config).length > 32000) {
        throw const AgentException('JavaScript 包清单、文件或设置无效。');
      }
      for (final item in configSchema.entries) {
        final s = object(item.value), v = config[item.key];
        if (v == null) continue;
        final valid = switch (s['type']) {
          'boolean' => v is bool,
          'number' || 'slider' =>
            v is num &&
                v.isFinite &&
                (s['min'] is! num || v >= (s['min'] as num)) &&
                (s['max'] is! num || v <= (s['max'] as num)),
          'enum' => (s['values'] as List? ?? []).contains(v),
          'string' => v is String,
          _ => false,
        };
        if (!valid) {
          throw AgentException(
            '设置 ${text(s['label']).isEmpty ? item.key : text(s['label'])} 的类型无效。',
          );
        }
      }
    }
    for (final origin in origins) {
      final uri = httpEndpoint(origin);
      if (uri.origin != origin) {
        throw const AgentException('allowedOrigins 必须为完整源地址（协议、域名、端口，不含路径）。');
      }
    }
    final names = <String>{};
    for (final tool in tools) {
      final n = text(tool['name']);
      if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]{0,63}$').hasMatch(n) ||
          !names.add(n) ||
          text(tool['description']).isEmpty ||
          object(tool['parameters'])['type'] != 'object') {
        throw const AgentException(
          '工具名称须唯一且只含英文、数字、下划线；需要 description 与 object 参数定义。',
        );
      }
      _schema(object(tool['parameters']));
      _validateHandler(object(tool['handler']));
    }
    for (final command in commands) {
      if (text(command['prefix']).trim().isEmpty ||
          text(command['prefix']).length > 60) {
        throw const AgentException('命令需要非空 prefix（最多 60 字符）。');
      }
      _validateHandler(object(command['handler']));
    }
  }

  void _validateHandler(Json handler) {
    final type = text(handler['type']);
    if (isJavaScript &&
        type == 'javascript' &&
        RegExp(
          r'^[a-zA-Z][a-zA-Z0-9_-]{0,39}$',
        ).hasMatch(text(handler['id']))) {
      return;
    }
    if (!{'template', 'http', 'script', 'time'}.contains(type)) {
      throw const AgentException(
        '扩展 handler.type 支持 template、http、script、time。',
      );
    }
    if (type == 'http') {
      final uri = httpEndpoint(text(handler['url']));
      if (!origins.contains(uri.origin) ||
          !{'GET', 'POST'}.contains(handler['method'] ?? 'GET') ||
          text(handler['url']).contains('{{')) {
        throw const AgentException(
          'HTTP 工具须声明 allowedOrigins，使用固定地址和 GET / POST。',
        );
      }
      for (final entry in object(handler['headers']).entries) {
        if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(entry.key) ||
            {
              'host',
              'content-length',
              'connection',
              'cookie',
            }.contains(entry.key.toLowerCase()) ||
            text(entry.value).contains(RegExp(r'[\r\n]'))) {
          throw const AgentException('HTTP 请求头无效。');
        }
      }
    }
    if (type == 'script' &&
        (text(handler['source']).trim().isEmpty ||
            text(handler['source']).length > 65536)) {
      throw const AgentException('脚本源码不能为空且不能超过 64 KB。');
    }
  }
}

void _schema(Json schema, [int depth = 0]) {
  if (depth > 6 ||
      schema.containsKey(r'$ref') ||
      !{
        'object',
        'array',
        'string',
        'number',
        'integer',
        'boolean',
      }.contains(schema['type'])) {
    throw const AgentException(
      '工具参数只支持 6 层以内的 object、array、string、number、integer、boolean。',
    );
  }
  if (schema['type'] == 'object') {
    final props = object(schema['properties']);
    if (props.length > 30 ||
        strings(schema['required']).any((k) => !props.containsKey(k))) {
      throw const AgentException('工具参数属性过多或 required 无效。');
    }
    for (final p in props.values) {
      _schema(object(p), depth + 1);
    }
  }
  if (schema['type'] == 'array') _schema(object(schema['items']), depth + 1);
}

void validateArguments(Object? value, Json schema, [int depth = 0]) {
  if (depth > 6) throw const AgentException('工具参数嵌套过深。');
  var valid = switch (schema['type']) {
    'object' => value is Map,
    'array' => value is List && value.length <= 100,
    'string' => value is String && value.length <= 8000,
    'number' => value is num && value.isFinite,
    'integer' => value is int,
    'boolean' => value is bool,
    _ => false,
  };
  if (schema['enum'] is List && !(schema['enum'] as List).contains(value)) {
    valid = false;
  }
  if (!valid) throw const AgentException('工具参数类型或枚举值无效。');
  if (value is Map) {
    final props = object(schema['properties']);
    if (strings(schema['required']).any((k) => !value.containsKey(k)) ||
        value.keys.any((k) => !props.containsKey(k))) {
      throw const AgentException('工具参数缺失或包含未知字段。');
    }
    for (final e in value.entries) {
      validateArguments(e.value, object(props[e.key]), depth + 1);
    }
  }
  if (value is List) {
    for (final e in value) {
      validateArguments(e, object(schema['items']), depth + 1);
    }
  }
}

class AgentExtensions {
  final AgentHttp http;
  final AgentScripts scripts;
  final AgentJsPackages? packages;
  AgentExtensions(this.http, this.scripts, {this.packages});
  Future<Json> execute(
    AgentExtension extension,
    Json handler,
    Json input, {
    CancelToken? cancel,
    required bool Function() active,
    AgentImageSender? sendImage,
    AgentTextSender? sendText,
    AgentMediaSender? sendMedia,
  }) async {
    if (!active()) throw const AgentException('任务已停止。');
    Json result;
    switch (handler['type']) {
      case 'javascript':
        if (!extension.isJavaScript || packages == null) {
          throw const AgentException('JavaScript 执行器不可用。');
        }
        final value = await packages!.run(
          manifest: extension.manifest,
          settings: extension.config,
          operation: 'tool',
          scope: text(input['scope']),
          input: input,
          args: {'id': handler['id'], 'args': object(input['args'])},
          active: active,
          cancel: cancel,
          sendImage: sendImage,
          sendText: sendText,
          sendMedia: sendMedia,
        );
        result = {
          'text': text(value['content'] ?? value['text'] ?? jsonEncode(value)),
          if (value['isError'] == true) 'isError': true,
        };
      case 'time':
        result = {'text': DateTime.now().toIso8601String()};
      case 'template':
        result = {'text': _render(text(handler['text']), input)};
      case 'script':
        result = await scripts.run(text(handler['source']), input);
      case 'http':
        final url = httpEndpoint(text(handler['url']));
        if (!extension.origins.contains(url.origin)) {
          throw const AgentException('扩展没有此接口的访问权限。');
        }
        final headers = object(handler['headers']).map(
          (k, v) => MapEntry(
            k,
            _render(text(v), {...input, 'secret': extension.secrets}),
          ),
        );
        if (headers.values.any((v) => v.contains(RegExp(r'[\r\n]')))) {
          throw const AgentException('HTTP 请求头含非法字符。');
        }
        final value = await http.request(
          url,
          method: text(handler['method']).isEmpty
              ? 'GET'
              : text(handler['method']),
          headers: headers,
          query: object(_renderObject(handler['query'], input)),
          body: handler['body'] == null
              ? null
              : object(_renderObject(handler['body'], input)),
          timeoutSeconds: 15,
          maxBytes: 262144,
          cancel: cancel,
        );
        final selected = text(handler['resultPath']).isEmpty
            ? value
            : _lookup(value, text(handler['resultPath']));
        result = {'text': selected is String ? selected : jsonEncode(selected)};
      default:
        throw const AgentException('未知扩展执行器。');
    }
    if (!active()) throw const AgentException('任务已停止。');
    // An HTTP service must not echo an extension secret back to the model.
    final redacted = object(
      redactAgentValue(result, [
        ...extension.secrets.values,
        ...extension.privateSettingValues,
      ]),
    );
    final serialized = jsonEncode(redacted);
    if (serialized.length > 65536) throw const AgentException('扩展结果过大。');
    return redacted;
  }
}

Object? _lookup(Object? value, String path) {
  for (final part in path.split('.')) {
    if (value is Map) {
      value = value[part];
    } else if (value is List &&
        int.tryParse(part) != null &&
        int.parse(part) >= 0 &&
        int.parse(part) < value.length) {
      value = value[int.parse(part)];
    } else {
      return null;
    }
  }
  return value;
}

String _render(String template, Json input) => template.replaceAllMapped(
  RegExp(r'\{\{([A-Za-z0-9_.]+)\}\}'),
  (m) => text(_lookup(input, m[1]!)),
);
Object? _renderObject(Object? value, Json input) {
  if (value is String) return _render(value, input);
  if (value is Map) {
    return value.map((k, v) => MapEntry(k, _renderObject(v, input)));
  }
  if (value is List) return value.map((v) => _renderObject(v, input)).toList();
  return value;
}
