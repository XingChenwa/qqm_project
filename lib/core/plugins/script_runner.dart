import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:hetu_script/hetu_script.dart';
import 'package:qqm_plugins/translate_comment/comment_spans.dart';

/// A separate, cancellable interpreter isolate. No Dart reflection, filesystem,
/// process, QQ credentials or platform channels are bound into the language.
class PluginScriptRunner {
  final _workers = <Isolate>{};
  bool _closed = false;
  final bool _inline;
  PluginScriptRunner() : _inline = false;

  /// Only for deterministic widget tests with trusted fixtures, never plugin installation.
  PluginScriptRunner.forTesting() : _inline = true;

  Future<Map<String, dynamic>> run(
    String source,
    Map<String, dynamic> context, {
    Duration timeout = const Duration(seconds: 3),
    Future<dynamic> Function(Map<String, dynamic>)? http,
  }) async {
    if (_closed) throw StateError('脚本运行器已关闭');
    if (_inline) {
      final result = await _evaluate(
        source,
        jsonDecode(jsonEncode(context)) as Map,
        http,
      );
      if (result['error'] != null) throw StateError(result['error'].toString());
      return result;
    }
    final port = ReceivePort();
    final finished = Completer<Map<String, dynamic>>();
    var requests = 0;
    var active = true;
    final subscription = port.listen((event) async {
      if (!active) return;
      if (event is Map && event['rpc'] is SendPort) {
        final reply = event['rpc'] as SendPort;
        try {
          if (++requests > 4 || http == null || event['request'] is! Map) {
            throw StateError('没有网络权限或请求次数超过限制');
          }
          final result = await http(
            Map<String, dynamic>.from(event['request']),
          );
          if (active) reply.send(result);
        } catch (_) {
          if (active) reply.send({'error': '网络请求失败或未获授权'});
        }
      } else if (event is Map && event['done'] == true) {
        if (!finished.isCompleted) {
          finished.complete(Map<String, dynamic>.from(event));
        }
      } else if ((event == null || event is List) && !finished.isCompleted) {
        finished.completeError(StateError('脚本运行进程异常退出'));
      }
    });
    Isolate? worker;
    try {
      worker = await Isolate.spawn(
        _scriptMain,
        [port.sendPort, source, jsonDecode(jsonEncode(context))],
        onError: port.sendPort,
        onExit: port.sendPort,
        errorsAreFatal: true,
        debugName: 'qqm-plugin-sandbox',
      );
      if (_closed) throw StateError('插件已停用');
      _workers.add(worker);
      final result = await finished.future.timeout(timeout);
      if (result['error'] != null) throw StateError(result['error'].toString());
      return result;
    } on TimeoutException {
      throw StateError('脚本执行超时，已终止，未保存本次数据');
    } finally {
      active = false;
      worker?.kill(priority: Isolate.immediate);
      if (worker != null) _workers.remove(worker);
      await subscription.cancel();
      port.close();
    }
  }

  void close() {
    _closed = true;
    for (final worker in _workers) {
      worker.kill(priority: Isolate.immediate);
    }
    _workers.clear();
  }
}

dynamic _plain(dynamic value, [int depth = 0, Set<Object>? seen]) {
  if (depth > 16) throw const FormatException('脚本数据嵌套过深');
  if (value == null || value is String || value is bool || value is num) {
    if (value is String && value.length > 524288) {
      throw const FormatException('脚本数据过长');
    }
    return value;
  }
  seen ??= Set.identity();
  if (!seen.add(value)) throw const FormatException('脚本数据包含循环引用');
  try {
    if (value is HTStruct) {
      if (value.keys.length > 2000) throw const FormatException('脚本对象过大');
      return {
        for (final key in value.keys) key: _plain(value[key], depth + 1, seen),
      };
    }
    if (value is Map) {
      if (value.length > 2000 || value.keys.any((k) => k is! String)) {
        throw const FormatException('脚本对象键名或大小无效');
      }
      return value.map(
        (key, entry) => MapEntry(key, _plain(entry, depth + 1, seen)),
      );
    }
    if (value is List) {
      if (value.length > 2000) throw const FormatException('脚本列表过大');
      return value.map((entry) => _plain(entry, depth + 1, seen)).toList();
    }
    throw const FormatException('脚本只能返回 JSON 数据');
  } finally {
    seen.remove(value);
  }
}

void _scriptMain(List<dynamic> input) async {
  final output = input[0] as SendPort;
  final result = await _evaluate(input[1] as String, input[2] as Map, (
    request,
  ) async {
    final response = ReceivePort();
    try {
      output.send({'rpc': response.sendPort, 'request': request});
      return await response.first;
    } finally {
      response.close();
    }
  });
  output.send(result);
}

Future<Map<String, dynamic>> _evaluate(
  String source,
  Map context,
  Future<dynamic> Function(Map<String, dynamic>)? http,
) async {
  var requests = 0;
  final random = Random.secure();
  try {
    RegExp regex(List<dynamic> args) {
      final pattern = args.first as String;
      if (pattern.length > 512) throw const FormatException('正则表达式过长');
      return RegExp(
        pattern,
        caseSensitive: args.length < 3 || args[2] != false,
      );
    }

    final ht = Hetu(
      config: HetuConfig(processError: false),
      sourceContext: HTOverlayContext(root: '/qqm-sandbox'),
    );
    ht.init(
      externalFunctions: {
        'print': ({positionalArgs, namedArgs}) {},
        'eval': ({positionalArgs, namedArgs}) =>
            throw StateError('动态 eval 不开放'),
        'require': ({positionalArgs, namedArgs}) => throw StateError('外部模块不开放'),
        'json_encode': ({positionalArgs, namedArgs}) =>
            jsonEncode(_plain(positionalArgs!.first)),
        'json_decode': ({positionalArgs, namedArgs}) =>
            jsonDecode(positionalArgs!.first as String),
        'json_try_decode': ({positionalArgs, namedArgs}) {
          try {
            return jsonDecode(positionalArgs!.first as String);
          } catch (_) {
            return null;
          }
        },
        'is_text': ({positionalArgs, namedArgs}) =>
            positionalArgs!.first is String,
        'keys': ({positionalArgs, namedArgs}) =>
            (_plain(positionalArgs!.first) as Map).keys.toList(),
        'is_map': ({positionalArgs, namedArgs}) =>
            positionalArgs!.first is Map || positionalArgs.first is HTStruct,
        'is_list': ({positionalArgs, namedArgs}) =>
            positionalArgs!.first is List,
        'str': ({positionalArgs, namedArgs}) =>
            positionalArgs!.first?.toString() ?? '',
        'integer': ({positionalArgs, namedArgs}) => positionalArgs!.first is num
            ? (positionalArgs.first as num).toInt()
            : int.tryParse('${positionalArgs.first}'),
        'rx': ({positionalArgs, namedArgs}) {
          final match = regex(
            positionalArgs!,
          ).firstMatch(positionalArgs[1] as String);
          return match == null
              ? null
              : [
                  for (var i = 0; i <= match.groupCount; i++)
                    match.group(i) ?? '',
                ];
        },
        'rx_all': ({positionalArgs, namedArgs}) => regex(positionalArgs!)
            .allMatches(positionalArgs[1] as String)
            .take(128)
            .map(
              (m) => [for (var i = 0; i <= m.groupCount; i++) m.group(i) ?? ''],
            )
            .toList(),
        'clean_name': ({positionalArgs, namedArgs}) {
          final name = '${positionalArgs!.first ?? ''}'
              .replaceAll(RegExp(r'[\r\n\x00-\x1f]'), ' ')
              .trim();
          return name.isEmpty
              ? 'QQ 用户'
              : String.fromCharCodes(name.runes.take(30));
        },
        'random_int': ({positionalArgs, namedArgs}) {
          final low = positionalArgs![0] as int,
              high = positionalArgs[1] as int;
          if (low > high || low.abs() > 1000000000 || high.abs() > 1000000000) {
            throw const FormatException('随机数范围无效');
          }
          return low + random.nextInt(high - low + 1);
        },
        'stable_hash': ({positionalArgs, namedArgs}) {
          var hash = 2166136261;
          for (final byte in utf8.encode(positionalArgs!.first as String)) {
            hash = ((hash ^ byte) * 16777619) & 0x7fffffff;
          }
          return hash;
        },
        'build_url': ({positionalArgs, namedArgs}) =>
            Uri.parse(positionalArgs![0] as String)
                .replace(
                  queryParameters: (_plain(positionalArgs[1]) as Map).map(
                    (k, v) => MapEntry(k as String, '$v'),
                  ),
                )
                .toString(),
        'markdown_escape': ({positionalArgs, namedArgs}) =>
            (positionalArgs!.first as String).replaceAllMapped(
              RegExp(r'[\\`*_{}\[\]()#+.!<>|~-]'),
              (m) => '\\${m[0]}',
            ),
        'comments': ({positionalArgs, namedArgs}) => CommentDocument.parse(
          positionalArgs![0] as String,
          positionalArgs[1] as String,
        ).comments,
        'replace_comments': ({positionalArgs, namedArgs}) =>
            CommentDocument.parse(
              positionalArgs![0] as String,
              positionalArgs[1] as String,
            ).replace(List<String>.from(positionalArgs[2] as List)),
        'http': ({positionalArgs, namedArgs}) async {
          final request = _plain(positionalArgs!.first);
          if (jsonEncode(request).length > 65536) {
            throw const FormatException('请求过大');
          }
          if (++requests > 4 || http == null) {
            return {'error': '没有网络权限或请求次数超过限制'};
          }
          return await http(Map<String, dynamic>.from(request as Map));
        },
      },
    );
    ht.eval('''
external function json_encode
external function json_decode
external function json_try_decode
external function is_text
external function keys
external function is_map
external function is_list
external function str
external function integer
external function rx
external function rx_all
external function clean_name
external function random_int
external function stable_hash
external function build_url
external function markdown_escape
external function comments
external function replace_comments
external function http
$source
''');
    final result = await ht.invoke('main', positionalArgs: [context]);
    final plain = _plain({
      'done': true,
      'result': result,
      'state': context['state'],
    });
    if (utf8.encode(jsonEncode(plain)).length > 524288) {
      throw const FormatException('脚本输出超过 512 KB');
    }
    return Map<String, dynamic>.from(plain as Map);
  } catch (error) {
    return {
      'done': true,
      'error': error is HTError
          ? '脚本错误 ${error.code}，行 ${error.line ?? 0}（行号包含 SDK 声明）'
          : error is CommentParseException
          ? error.message
          : '脚本执行失败，请检查语法和返回值',
    };
  }
}
