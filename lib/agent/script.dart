import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:hetu_script/hetu_script.dart';
import 'models.dart';

/// Agent-only interpreter. No original bot plugin context or host bindings.
class AgentScripts {
  final _workers = <Isolate>{};
  bool _closed = false;
  Future<Json> run(String source, Json input) async {
    if (_closed) throw const AgentException('Agent 脚本运行器已关闭。');
    final port = ReceivePort();
    Isolate? worker;
    try {
      final result = port.first;
      worker = await Isolate.spawn(
        _worker,
        [port.sendPort, source, jsonEncode(input)],
        onError: port.sendPort,
        onExit: port.sendPort,
        errorsAreFatal: true,
        debugName: 'qqm-agent-script',
      );
      if (_closed) throw const AgentException('Agent 脚本运行器已关闭。');
      _workers.add(worker);
      final value = await result.timeout(const Duration(seconds: 3));
      if (value is! Map || value['ok'] != true) {
        throw const AgentException('Agent 脚本执行失败，请检查 run(input) 和返回的 JSON。');
      }
      return object(value['result']);
    } on TimeoutException {
      throw const AgentException('Agent 脚本超过 3 秒，已终止。');
    } finally {
      worker?.kill(priority: Isolate.immediate);
      if (worker != null) _workers.remove(worker);
      port.close();
    }
  }

  void close() {
    _closed = true;
    for (final w in _workers) {
      w.kill(priority: Isolate.immediate);
    }
    _workers.clear();
  }
}

dynamic _jsonValue(dynamic value, [int depth = 0]) {
  if (depth > 12) throw const FormatException('depth');
  if (value == null || value is bool || value is num) return value;
  if (value is String) {
    if (value.length > 65536) throw const FormatException('size');
    return value;
  }
  if (value is HTStruct) {
    return {for (final k in value.keys) k: _jsonValue(value[k], depth + 1)};
  }
  if (value is Map) {
    return value.map((k, v) => MapEntry('$k', _jsonValue(v, depth + 1)));
  }
  if (value is List && value.length <= 1000) {
    return value.map((v) => _jsonValue(v, depth + 1)).toList();
  }
  throw const FormatException('json');
}

void _worker(List<dynamic> args) {
  final port = args[0] as SendPort;
  try {
    final ht = Hetu(
      config: HetuConfig(processError: false),
      sourceContext: HTOverlayContext(root: '/qqm-agent-sandbox'),
    );
    ht.init(
      externalFunctions: {
        'print': ({positionalArgs, namedArgs}) {},
        'eval': ({positionalArgs, namedArgs}) =>
            throw const FormatException('eval disabled'),
        'require': ({positionalArgs, namedArgs}) =>
            throw const FormatException('modules disabled'),
        'json_decode': ({positionalArgs, namedArgs}) =>
            jsonDecode(positionalArgs!.first as String),
        'json_encode': ({positionalArgs, namedArgs}) =>
            jsonEncode(_jsonValue(positionalArgs!.first)),
        'now_iso': ({positionalArgs, namedArgs}) =>
            DateTime.now().toIso8601String(),
      },
    );
    ht.eval(args[1] as String);
    final result = ht.invoke('run', positionalArgs: [args[2]]);
    final raw = result is String ? result : jsonEncode(_jsonValue(result));
    if (raw.length > 65536) throw const FormatException('size');
    final json = jsonDecode(raw);
    if (json is! Map) throw const FormatException('object');
    port.send({'ok': true, 'result': json});
  } catch (_) {
    port.send({'ok': false});
  }
}
