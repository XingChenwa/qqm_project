import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
// Deliberately use the pure Dart FFI binding. Importing the Flutter wrapper
// would make the authenticated, headless Linux server depend on dart:ui.
import 'package:flutter_qjs_next/quickjs/ffi.dart' as qjs;
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import 'models.dart';
import 'store.dart';
import 'http.dart';
import 'js_bootstrap.dart';
import 'audio.dart';

typedef AgentImageSender = Future<Json> Function(Uint8List bytes, String name);
typedef AgentTextSender = Future<Json> Function(String message);
typedef AgentMediaSender =
    Future<Json> Function(Uint8List bytes, String name, String type);
typedef AgentHostCall = Future<Object?> Function(String operation, Json args);

/// One immutable package + one account's writable volume per invocation.
/// No platform channel, Node process, app directory, env or bot token is exposed.
class AgentJsPackages {
  final AgentStore store;
  final AgentHttp http;
  final _queues = <String, Future<void>>{};
  final _sessions = <String, _PackageSession>{};
  AgentJsPackages(this.store, this.http);
  Future<void> drain() async {
    await Future.wait(_queues.values.toList());
    final sessions = _sessions.values.toList();
    _sessions.clear();
    await Future.wait(sessions.map((s) => s.close()));
  }

  Future<void> stopScope(String scope) async {
    final matches = _sessions.entries
        .where((e) => e.value.scope == scope)
        .toList();
    for (final e in matches) {
      _sessions.remove(e.key);
    }
    await Future.wait(matches.map((e) => e.value.close()));
  }

  Future<void> stopAll() async {
    final sessions = _sessions.values.toList();
    _sessions.clear();
    await Future.wait(sessions.map((s) => s.close()));
  }

  Future<Json> run({
    required Json manifest,
    required Json settings,
    required String operation,
    String scope = 'inspect',
    Json args = const {},
    Json input = const {},
    CancelToken? cancel,
    required bool Function() active,
    AgentImageSender? sendImage,
    AgentTextSender? sendText,
    AgentMediaSender? sendMedia,
    AgentHostCall? hostCall,
    bool Function()? runtimeActive,
    bool persistent = false,
    String? sourceRevision,
  }) {
    final id = text(manifest['id']);
    final key = 'js-volume:$id:${base64Url.encode(utf8.encode(scope))}';
    final completer = Completer<Json>();
    final previous = _queues[key] ?? Future<void>.value();
    final work = previous.then((_) async {
      if (!active()) throw const AgentException('任务已停止。');
      final useSession =
          operation != 'inspect' &&
          (persistent ||
              {
                'activate',
                'hook',
                'provider',
                'capability',
                'deactivate',
              }.contains(operation) ||
              _sessions.containsKey(key) ||
              strings(object(manifest['compatibility'])['hooks']).isNotEmpty ||
              strings(
                object(manifest['compatibility'])['providers'],
              ).any((v) => v != 'message.owner-check'));
      Json outcome;
      if (useSession) {
        final signature =
            sourceRevision ??
            sha256
                .convert(utf8.encode(jsonEncode([manifest, settings])))
                .toString();
        var session = _sessions[key];
        if (session != null &&
            (session.signature != signature || session.closed)) {
          _sessions.remove(key);
          await session.close();
          session = null;
        }
        session ??= _sessions[key] = _PackageSession(
          this,
          key,
          scope,
          signature,
          manifest,
          settings,
          runtimeActive ?? () => true,
        );
        outcome = {
          'ok': true,
          'result': await session.invoke(
            operation,
            args,
            input,
            active,
            cancel,
            sendImage,
            sendText,
            sendMedia,
            hostCall,
          ),
        };
      } else {
        outcome = await _worker(
          manifest: manifest,
          settings: settings,
          volume: operation == 'inspect' ? {} : store.get(key) ?? {},
          operation: operation,
          args: args,
          input: input,
          active: active,
          cancel: cancel,
          sendImage: sendImage,
          sendText: sendText,
          sendMedia: sendMedia,
          hostCall: hostCall,
        );
      }
      if (!active() || cancel?.isCancelled == true) {
        throw const AgentException('任务已停止。');
      }
      if (operation != 'inspect' && outcome['dirty'] == true) {
        await store.put(key, object(outcome['volume']));
      }
      if (outcome['ok'] != true) throw AgentException(text(outcome['error']));
      return object(outcome['result']);
    });
    final tail = work.then<void>(
      completer.complete,
      onError: (Object e, StackTrace s) => completer.completeError(e, s),
    );
    _queues[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_queues[key], tail)) _queues.remove(key);
      }),
    );
    return completer.future;
  }

  Future<Json> _worker({
    required Json manifest,
    required Json settings,
    required Json volume,
    required String operation,
    required Json args,
    required Json input,
    required bool Function() active,
    CancelToken? cancel,
    AgentImageSender? sendImage,
    AgentTextSender? sendText,
    AgentMediaSender? sendMedia,
    AgentHostCall? hostCall,
  }) async {
    final port = ReceivePort();
    final complete = Completer<Json>();
    final requests = <int, CancelToken>{};
    final sockets = <String, _AgentSocketPump>{};
    var socketSerial = 0;
    final workerDone = Completer<void>();
    SendPort? workerPort;
    var cancelled = false, finished = false;
    Future<void> request(Json message) async {
      final token = CancelToken();
      requests[integer(message['id'], 0)] = token;
      try {
        if (!active() || cancelled || cancel?.isCancelled == true) {
          throw const AgentException('任务已停止。');
        }
        final a = object(message['args']);
        Object? value;
        switch (message['op']) {
          case 'socketOpen':
            if (sockets.length >= 2) {
              throw const AgentException('插件最多同时使用两个语音连接。');
            }
            final socket = await http.openWebSocket(
              Uri.parse(text(a['url'])),
              headers: object(a['headers']).map((k, v) => MapEntry(k, text(v))),
            );
            if (!active() || cancelled || finished) {
              await socket.close();
              throw const AgentException('任务已停止。');
            }
            final id = 'socket-${++socketSerial}';
            sockets[id] = _AgentSocketPump(socket);
            value = {'id': id};
          case 'socketNext':
            final socket = sockets[text(a['id'])];
            if (socket == null) throw const AgentException('语音连接已关闭。');
            value = await socket.next();
          case 'socketSend':
            final socket = sockets[text(a['id'])];
            if (socket == null) throw const AgentException('语音连接已关闭。');
            final payload = text(a['data']);
            if (payload.length > 256 * 1024) {
              throw const AgentException('语音请求帧过大。');
            }
            socket.send(a['binary'] == true ? base64Decode(payload) : payload);
            value = null;
          case 'socketClose':
            await sockets.remove(text(a['id']))?.close();
            value = null;
          case 'fetch':
            final r = await http.fetchBytes(
              Uri.parse(text(a['url'])),
              method: text(a['method']),
              headers: object(a['headers']).map((k, v) => MapEntry(k, text(v))),
              body: a['body'],
              cancel: token,
              timeoutSeconds: integer(a['timeoutSeconds'], 15),
            );
            value = {
              'bytes': r.bytes,
              'status': r.status,
              'headers': r.headers,
            };
          case 'image':
            if (sendImage == null) throw const AgentException('当前上下文不能发送图片。');
            value = await sendImage(a['bytes'] as Uint8List, text(a['name']));
          case 'text':
            if (sendText == null) throw const AgentException('当前上下文不能发送消息。');
            value = await sendText(text(a['text']));
          case 'media':
            if (sendMedia == null) throw const AgentException('当前上下文不能发送语音。');
            value = await sendMedia(
              a['bytes'] as Uint8List,
              text(a['name']),
              text(a['type']),
            );
          case 'host':
            if (hostCall == null) throw const AgentException('此插件服务尚未启用。');
            value = await hostCall(text(a['operation']), object(a['args']));
          default:
            throw const AgentException('未知扩展线程请求。');
        }
        if (!finished) workerPort?.send({'id': message['id'], 'value': value});
      } catch (e) {
        if (!finished) {
          workerPort?.send({
            'id': message['id'],
            'error': e is AgentException ? e.message : '扩展请求失败。',
          });
        }
      } finally {
        requests.remove(integer(message['id'], 0));
      }
    }

    final subscription = port.listen((message) {
      if (finished) return;
      if (message is Map) {
        if (message['type'] == 'ready') {
          workerPort = message['port'] as SendPort;
          if (cancelled) workerPort!.send({'cancel': true});
        } else if (message['type'] == 'cancelRequest') {
          requests[integer(message['id'], 0)]?.cancel();
        } else if (message['type'] == 'request') {
          unawaited(request(object(message)));
        } else if (message['type'] == 'done') {
          if (!workerDone.isCompleted) workerDone.complete();
          if (!complete.isCompleted) {
            complete.complete(object(message['value']));
          }
        }
      } else {
        if (!workerDone.isCompleted) workerDone.complete();
        if (!complete.isCompleted) {
          complete.completeError(const AgentException('扩展运行线程意外停止，任务已取消。'));
        }
      }
    });
    Isolate? worker;
    Timer? cancelTimer, deadline;
    try {
      worker = await Isolate.spawn(
        _agentPackageWorker,
        {
          'out': port.sendPort,
          'manifest': manifest,
          'settings': settings,
          'volume': volume,
          'operation': operation,
          'args': args,
          'input': input,
          'hasHost': hostCall != null,
        },
        onExit: port.sendPort,
        onError: port.sendPort,
        errorsAreFatal: true,
        debugName: 'qqm-agent-${text(manifest['id'])}',
      );
      final started = DateTime.now();
      cancelTimer = Timer.periodic(
        Duration(milliseconds: operation == 'session' ? 100 : 20),
        (_) {
          if (!cancelled && (!active() || cancel?.isCancelled == true)) {
            cancelled = true;
            workerPort?.send({'cancel': true});
            for (final request in requests.values) {
              request.cancel();
            }
            if (!complete.isCompleted) {
              complete.completeError(const AgentException('任务已停止。'));
            }
          }
          if (operation != 'session' &&
              DateTime.now().difference(started).inSeconds >
                  packageExecutionSeconds(settings) + 5 &&
              !complete.isCompleted) {
            complete.completeError(const AgentException('扩展超过运行时间限制。'));
          }
        },
      );
      if (operation != 'session') {
        deadline = Timer(
          Duration(seconds: packageExecutionSeconds(settings) + 6),
          () {
            if (!complete.isCompleted) {
              complete.completeError(const AgentException('扩展超过运行时间限制。'));
            }
          },
        );
      }
      return await complete.future;
    } finally {
      cancelTimer?.cancel();
      deadline?.cancel();
      workerPort?.send({'cancel': true});
      for (final request in requests.values) {
        request.cancel();
      }
      await Future.wait(sockets.values.map((socket) => socket.close()));
      sockets.clear();
      if (worker != null && !workerDone.isCompleted) {
        cancelled = true;
        try {
          await workerDone.future.timeout(const Duration(seconds: 3));
        } catch (_) {
          /* Native interrupt is bounded; kill only after allowing finally cleanup. */
        }
      }
      finished = true;
      worker?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      port.close();
    }
  }
}

class _AgentSocketPump {
  final AgentWebSocket socket;
  final _events = <Json>[];
  late final StreamSubscription<Object> _subscription;
  late final Timer _deadline;
  Completer<void>? _waiting;
  bool _closed = false;
  int _bytes = 0;
  _AgentSocketPump(this.socket) {
    _deadline = Timer(const Duration(seconds: 30), () {
      _push({'type': 'error', 'message': '语音连接超时'});
      unawaited(close());
    });
    _subscription = socket.messages.listen(
      (value) {
        final bytes = value is String
            ? utf8.encode(value)
            : value is List<int>
            ? value
            : <int>[];
        _bytes += bytes.length;
        if (_bytes > 6 * 1024 * 1024 || _events.length >= 128) {
          _push({'type': 'error', 'message': '语音数据超过限制'});
          unawaited(close());
          return;
        }
        _push({
          'type': 'message',
          'binary': value is! String,
          'data': value is String ? value : base64Encode(bytes),
        });
      },
      onError: (Object _) {
        _push({'type': 'error', 'message': '语音连接中断'});
        unawaited(close());
      },
      onDone: () {
        _push({'type': 'close'});
        unawaited(close());
      },
    );
  }
  void _push(Json event) {
    if (_closed) return;
    _events.add(event);
    if (_waiting?.isCompleted == false) _waiting!.complete();
  }

  Future<List<Json>> next() async {
    if (_events.isEmpty && !_closed) {
      final waiter = Completer<void>();
      _waiting = waiter;
      await waiter.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
      if (identical(_waiting, waiter)) _waiting = null;
    }
    if (_events.isEmpty && _closed) {
      return [
        {'type': 'close'},
      ];
    }
    final items = _events.take(32).toList();
    _events.removeRange(0, items.length);
    return items;
  }

  void send(Object data) {
    if (_closed) throw const AgentException('语音连接已关闭。');
    socket.add(data);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _deadline.cancel();
    if (_waiting?.isCompleted == false) _waiting!.complete();
    await _subscription.cancel();
    await socket.close();
  }
}

class _PackageInvocation {
  final bool Function() active;
  final AgentImageSender? image;
  final AgentTextSender? text;
  final AgentMediaSender? media;
  final AgentHostCall? host;
  _PackageInvocation(this.active, this.image, this.text, this.media, this.host);
  void check() {
    if (!active()) throw const AgentException('插件上下文已失效。');
  }
}

/// One original ESM module stays alive per extension + account. Its Maps,
/// closures and timers therefore survive lifecycle hooks and tool calls.
class _PackageSession {
  final AgentJsPackages owner;
  final String key, scope, signature;
  final Json manifest, settings;
  final bool Function() runtimeActive;
  final _cancel = CancelToken();
  Completer<Json>? _pull, _result;
  Json? _job;
  _PackageInvocation? _context, _ambient;
  Future<void>? _worker;
  int _id = 0;
  bool closed = false;
  _PackageSession(
    this.owner,
    this.key,
    this.scope,
    this.signature,
    this.manifest,
    this.settings,
    this.runtimeActive,
  );
  bool get alive => !closed && owner.store.isOpen && runtimeActive();
  void _launch() {
    _worker = owner
        ._worker(
          manifest: manifest,
          settings: settings,
          volume: owner.store.get(key) ?? {},
          operation: 'session',
          args: {},
          input: {},
          active: () => alive,
          cancel: _cancel,
          hostCall: _host,
          sendImage: (bytes, name) async {
            final c = _context ?? _ambient;
            c?.check();
            if (c?.image == null) throw const AgentException('当前插件不能发送图片。');
            return c!.image!(bytes, name);
          },
          sendText: (message) async {
            final c = _context ?? _ambient;
            c?.check();
            if (c?.text == null) throw const AgentException('当前插件不能发送消息。');
            return c!.text!(message);
          },
          sendMedia: (bytes, name, type) async {
            final c = _context ?? _ambient;
            c?.check();
            if (c?.media == null) throw const AgentException('当前插件不能发送语音。');
            return c!.media!(bytes, name, type);
          },
        )
        .then<void>(
          (result) {
            if (!closed) {
              _fail(
                text(result['error']).isEmpty
                    ? '插件运行时已停止'
                    : text(result['error']),
              );
            }
          },
          onError: (Object e) {
            if (!closed) _fail(e is AgentException ? e.message : '插件运行时已停止');
          },
        );
  }

  void _fail(String reason) {
    if (_result?.isCompleted == false) {
      _result!.completeError(AgentException(reason));
    }
    unawaited(close());
  }

  Future<Json> invoke(
    String operation,
    Json args,
    Json input,
    bool Function() active,
    CancelToken? cancel,
    AgentImageSender? image,
    AgentTextSender? textSender,
    AgentMediaSender? media,
    AgentHostCall? host,
  ) async {
    if (!alive) throw const AgentException('插件运行时已停止。');
    final id = ++_id, result = Completer<Json>();
    _result = result;
    _context = _PackageInvocation(active, image, textSender, media, host);
    if (operation == 'activate') _ambient = _context;
    final job = {
      'id': id,
      'operation': operation,
      'args': args,
      'input': input,
    };
    if (_pull != null) {
      final pull = _pull!;
      _pull = null;
      pull.complete(job);
    } else {
      _job = job;
    }
    if (_worker == null) _launch();
    final watch = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (!active() || cancel?.isCancelled == true) {
        _fail('任务已停止。');
      }
    });
    try {
      return await result.future.timeout(
        Duration(seconds: packageExecutionSeconds(settings) + 5),
        onTimeout: () {
          _fail('插件执行超过时间限制，已停止。');
          throw const AgentException('插件执行超过时间限制，已停止。');
        },
      );
    } finally {
      watch.cancel();
      if (identical(_result, result)) {
        _result = null;
        _context = null;
      }
    }
  }

  Future<void> _checkpoint(Json value) async {
    if (value['dirty'] == true && alive) {
      await owner.store.put(key, object(value['volume']));
    }
  }

  Future<Object?> _host(String operation, Json args) async {
    if (!alive) throw const AgentException('插件运行时已停止。');
    if (operation == 'nextJob') {
      if (_job != null) {
        final job = _job!;
        _job = null;
        return job;
      }
      final pull = Completer<Json>();
      _pull = pull;
      return pull.future;
    }
    if (operation == 'checkpoint') {
      await _checkpoint(args);
      return null;
    }
    if (operation == 'jobDone') {
      if (integer(args['id'], 0) != _id || _result == null) {
        throw const AgentException('插件任务序号无效。');
      }
      _context?.check();
      await _checkpoint(args);
      final result = _result!;
      if (!result.isCompleted) {
        if (text(args['error']).isNotEmpty) {
          result.completeError(AgentException(text(args['error'])));
        } else {
          result.complete(object(args['result']));
        }
      }
      return null;
    }
    final c = _context ?? _ambient;
    c?.check();
    if (c?.host == null) throw const AgentException('当前插件服务不可用。');
    return c!.host!(operation, args);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    _cancel.cancel();
    if (_pull?.isCompleted == false) {
      _pull!.completeError(const AgentException('插件运行时已停止。'));
    }
    _pull = null;
    if (_result?.isCompleted == false) {
      _result!.completeError(const AgentException('插件运行时已停止。'));
    }
    await _worker;
  }
}

// Only these serializable values enter the worker. No Hive box, model API Key,
// connection object, UI state or main-isolate closure crosses the boundary.
Future<void> _agentPackageWorker(Json job) async {
  final out = job['out'] as SendPort, port = ReceivePort();
  final wake = _EngineWake();
  var current = true, serial = 0;
  final pending = <int, Completer<Object?>>{};
  Future<Object?> request(String op, Json args, [CancelToken? cancel]) {
    if (!current) return Future.error(const AgentException('任务已停止。'));
    final id = ++serial, c = Completer<Object?>();
    pending[id] = c;
    unawaited(
      cancel?.whenCancel.then((_) {
        if (!c.isCompleted) {
          pending.remove(id);
          out.send({'type': 'cancelRequest', 'id': id});
          c.completeError(const AgentException('请求已停止。'));
        }
      }),
    );
    out.send({'type': 'request', 'id': id, 'op': op, 'args': args});
    return c.future;
  }

  final subscription = port.listen((message) {
    if (message is! Map) return;
    wake.pulse();
    if (message['cancel'] == true) {
      current = false;
      for (final c in pending.values) {
        if (!c.isCompleted) c.completeError(const AgentException('任务已停止。'));
      }
      pending.clear();
    } else {
      final c = pending.remove(message['id']);
      if (c != null && !c.isCompleted) {
        if (message['error'] != null) {
          c.completeError(AgentException(text(message['error'])));
        } else {
          c.complete(message['value']);
        }
      }
    }
  });
  out.send({'type': 'ready', 'port': port.sendPort});
  final http = _WorkerHttp(request);
  final engine = _PackageEngine(
    manifest: object(job['manifest']),
    settings: object(job['settings']),
    volume: object(job['volume']),
    operation: text(job['operation']),
    http: http,
    socketCall: (op, args) => request(op, args),
    wake: wake,
    active: () => current,
    sendImage: (bytes, name) async =>
        object(await request('image', {'bytes': bytes, 'name': name})),
    sendText: (message) async =>
        object(await request('text', {'text': message})),
    sendMedia: (bytes, name, type) async => object(
      await request('media', {'bytes': bytes, 'name': name, 'type': type}),
    ),
    hostCall: job['hasHost'] == true
        ? (op, args) => request('host', {'operation': op, 'args': args})
        : null,
  );
  Json result;
  try {
    result = {
      'ok': true,
      'result': await engine.run(object(job['args']), object(job['input'])),
    };
  } catch (e) {
    result = {
      'ok': false,
      'error': e is AgentException ? e.message : 'JavaScript 扩展运行失败。',
    };
  } finally {
    engine.close();
    http.close();
    await subscription.cancel();
    port.close();
  }
  out.send({
    'type': 'done',
    'value': {...result, 'volume': engine.volume, 'dirty': engine.dirty},
  });
}

class _WorkerHttp extends AgentHttp {
  final Future<Object?> Function(String, Json, [CancelToken?]) forward;
  _WorkerHttp(this.forward);
  @override
  Future<({Uint8List bytes, int status, Map<String, String> headers})>
  fetchBytes(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    CancelToken? cancel,
    int maxBytes = 12 * 1024 * 1024,
    int timeoutSeconds = 15,
  }) async {
    final r = object(
      await forward('fetch', {
        'url': uri.toString(),
        'method': method,
        'headers': headers,
        'body': body,
        'timeoutSeconds': timeoutSeconds,
      }, cancel),
    );
    if (cancel?.isCancelled == true) throw const AgentException('任务已停止。');
    return (
      bytes: r['bytes'] as Uint8List,
      status: integer(r['status'], 0),
      headers: object(r['headers']).map((k, v) => MapEntry(k, text(v))),
    );
  }
}

/// Sleeps until real I/O, a new job, cancellation, or the next JS timer. The
/// generation check prevents a response arriving during evaluation being lost.
class _EngineWake {
  int generation = 0;
  Completer<void>? _waiting;
  void pulse() {
    generation++;
    if (_waiting?.isCompleted == false) _waiting!.complete();
  }

  Future<void> wait(int observed, Duration delay) async {
    if (generation != observed || delay <= Duration.zero) return;
    final waiting = Completer<void>();
    _waiting = waiting;
    final timer = Timer(delay, () {
      if (!waiting.isCompleted) waiting.complete();
    });
    try {
      await waiting.future;
    } finally {
      timer.cancel();
      if (identical(_waiting, waiting)) _waiting = null;
    }
  }
}

class _PackageEngine {
  final Json manifest, settings, volume;
  final String operation;
  final AgentHttp http;
  final Future<Object?> Function(String, Json) socketCall;
  final _EngineWake wake;
  final bool Function() active;
  final AgentImageSender? sendImage;
  final AgentTextSender? sendText;
  final AgentMediaSender? sendMedia;
  final AgentHostCall? hostCall;
  final _port = ReceivePort();
  final _requests = <int, CancelToken>{};
  final _directories = <String>{'/data', '/tmp'};
  final _logs = <String>[];
  Pointer<qjs.JSRuntime>? _runtime;
  Pointer<qjs.JSContext>? _context;
  int _serial = 0, _calls = 0, _bytes = 0;
  int _revision = 0;
  DateTime _requestWindow = DateTime.now(), _checkpointAt = DateTime.now();
  bool _checkpointing = false;
  Json _hostInput = {};
  bool dirty = false, _disposed = false;
  late final String root = '/packages/${text(manifest['id'])}';
  late final Json files = object(manifest['files']);
  late final Json original = object(manifest['packageManifest']);
  late final List<String> permissions = strings(original['permissions']);
  _PackageEngine({
    required this.manifest,
    required this.settings,
    required this.volume,
    required this.operation,
    required this.http,
    required this.socketCall,
    required this.wake,
    required this.active,
    this.sendImage,
    this.sendText,
    this.sendMedia,
    this.hostCall,
  });

  void _check() {
    if (_disposed || !active()) {
      throw const AgentException('任务已停止。');
    }
  }

  Future<Json> run(Json args, Json input) async {
    _check();
    _hostInput = input;
    try {
      _runtime = qjs.jsNewRuntime(
        _channel,
        3000,
        _port,
        memoryLimit: 96 * 1024 * 1024,
      );
      qjs.jsSetMemoryLimit(_runtime!, 96 * 1024 * 1024);
      qjs.jsSetMaxStackSize(
        _runtime!,
        Platform.isWindows ? 256 * 1024 : 512 * 1024,
      );
      _context = qjs.jsNewContext(_runtime!);
      // One JSON-only synchronous native function; arbitrary Dart objects and
      // FFI addresses are never passed to JavaScript.
      final ctx = _context!;
      final global = qjs.jsEval(ctx, 'globalThis', '<host>', 0);
      final name = qjs.jsNewString(ctx, '__agentNative');
      final atom = qjs.jsValueToAtom(ctx, name);
      final data = qjs.jsNewString(ctx, 'host');
      final function = qjs.jsNewCFunction(ctx, data);
      qjs.jsDefinePropertyValue(ctx, global, atom, function, qjs.JSProp.C_W_E);
      qjs.jsFreeAtom(ctx, atom);
      qjs.jsFreeValue(ctx, name);
      qjs.jsFreeValue(ctx, data);
      qjs.jsFreeValue(ctx, global);
      _eval(agentJsBootstrap);
      final entry = text(manifest['entry']).isEmpty
          ? 'index.js'
          : text(manifest['entry']);
      final code =
          '''import * as entry from ${jsonEncode('$root/$entry')};
        globalThis.__agent.start((async()=>{
          const value=await globalThis.__agent.load(entry,${jsonEncode(settings)},${jsonEncode(operation)});
          return globalThis.__agent.run(${jsonEncode(operation)},${operation == 'inspect' ? 'value' : jsonEncode(args)},${jsonEncode(input)});
        })());''';
      _eval(code, module: true);
      final deadline = DateTime.now().add(
        Duration(
          seconds: operation == 'inspect'
              ? 5
              : packageExecutionSeconds(settings),
        ),
      );
      while (true) {
        final observed = wake.generation;
        _check();
        if (operation != 'session' && DateTime.now().isAfter(deadline)) {
          throw const AgentException('JavaScript 扩展运行超时，已停止。');
        }
        _eval('globalThis.__agent.tick();');
        if (operation == 'session' &&
            dirty &&
            !_checkpointing &&
            DateTime.now().difference(_checkpointAt).inSeconds >= 1) {
          _checkpointing = true;
          _checkpointAt = DateTime.now();
          unawaited(_checkpoint().whenComplete(() => _checkpointing = false));
        }
        // Bound even an adversarial chain of Promise callbacks; native QuickJS
        // also interrupts each individual job / evaluation after 3 seconds.
        for (var i = 0; i < 100 && qjs.jsIsJobPending(_runtime!) != 0; i++) {
          if (qjs.jsExecutePendingJob(_runtime!) < 0) {
            throw const AgentException('JavaScript 异步任务失败。');
          }
        }
        final poll = object(
          jsonDecode(_eval('JSON.stringify(globalThis.__agent.poll())')),
        );
        if (poll['finished'] == true) {
          final failure = text(poll['failure']);
          if (failure.isNotEmpty) {
            throw AgentException(
              '扩展 ${text(manifest['name'])}：${clipped(failure, 300)}',
            );
          }
          return {
            ...object(poll['result']),
            if (_logs.isNotEmpty) '_logs': _logs,
          };
        }
        if (qjs.jsIsJobPending(_runtime!) != 0) {
          await Future<void>.delayed(Duration.zero);
        } else {
          await wake.wait(
            observed,
            Duration(
              milliseconds: integer(poll['waitMs'], 1000).clamp(1, 1000),
            ),
          );
        }
      }
    } on AgentException {
      rethrow;
    } catch (_) {
      throw const AgentException('JavaScript 引擎未能启动或扩展语法无效。请使用包含内嵌引擎的新版客户端。');
    }
  }

  String _eval(String code, {bool module = false}) {
    _check();
    final value = qjs.jsEval(
      _context!,
      code,
      '<agent>',
      module ? qjs.JSEvalFlag.MODULE : qjs.JSEvalFlag.GLOBAL,
    );
    try {
      if (qjs.jsIsException(value) != 0) {
        final error = qjs.jsGetException(_context!);
        try {
          throw AgentException(
            'JavaScript 扩展错误：${clipped(qjs.jsToCString(_context!, error), 300)}',
          );
        } finally {
          qjs.jsFreeValue(_context!, error);
        }
      }
      if (module) {
        final attach = qjs.jsEval(
          _context!,
          '(promise)=>Promise.resolve(promise).catch(error=>{globalThis.__agent.failure=String(error);globalThis.__agent.finished=true;})',
          '<module-result>',
          0,
        );
        final receiver = qjs.jsUNDEFINED();
        final result = qjs.jsCall(_context!, attach, receiver, [value]);
        qjs.jsFreeValue(_context!, result);
        qjs.jsFreeValue(_context!, receiver);
        qjs.jsFreeValue(_context!, attach);
      }
      return qjs.jsToCString(_context!, value);
    } finally {
      qjs.jsFreeValue(_context!, value);
    }
  }

  Pointer<qjs.JSValue> _channel(
    Pointer<qjs.JSContext> ctx,
    int type,
    Pointer<qjs.JSValue> ptr,
  ) {
    if (type == qjs.JSChannelType.MODULE) {
      try {
        final name = ptr.cast<Utf8>().toDartString();
        final builtins = <String, List<String>>{
          'fs': [
            'readFileSync',
            'writeFileSync',
            'mkdirSync',
            'readdirSync',
            'statSync',
            'existsSync',
            'renameSync',
            'unlinkSync',
            'promises',
          ],
          'fs/promises': [
            'readFile',
            'writeFile',
            'mkdir',
            'readdir',
            'stat',
            'unlink',
            'rename',
          ],
          'path': [
            'join',
            'resolve',
            'dirname',
            'basename',
            'extname',
            'normalize',
            'isAbsolute',
            'posix',
            'sep',
            'delimiter',
          ],
          'os': ['tmpdir', 'platform'],
          'url': ['URL', 'URLSearchParams', 'fileURLToPath', 'pathToFileURL'],
          'crypto': ['createHash', 'randomUUID'],
          'buffer': ['Buffer'],
          'child_process': [
            'spawn',
            'spawnSync',
            'exec',
            'execSync',
            'execFile',
            'execFileSync',
            'fork',
          ],
          'qqm-config': ['DATA_DIR', 'getConfig', 'updateConfig'],
          'qqm-logger': ['logger'],
          'qqm-safe-fetch': ['validateImageUrl'],
          'qqm-stickers': ['localStickerPath'],
          'qqm-model-prices': ['resolveModelPrice', 'priceAt', 'modelLabel'],
          'qqm-tool-registry': ['getToolAvailability'],
        };
        var key = name.replaceFirst(RegExp(r'^node:'), '');
        final legacy = name.replaceFirst(RegExp(r'^file://'), '');
        for (final prefix in ['src/', '/src/', '/qqm-compat/src/']) {
          if (!legacy.startsWith(prefix)) continue;
          key = switch (legacy.substring(prefix.length)) {
            'config.js' => 'qqm-config',
            'logger.js' => 'qqm-logger',
            'safe-fetch.js' => 'qqm-safe-fetch',
            'sticker-manager.js' => 'qqm-stickers',
            'model-prices.js' => 'qqm-model-prices',
            'tool-registry.js' => 'qqm-tool-registry',
            _ => key,
          };
        }
        if (builtins.containsKey(key)) {
          return ('const m=globalThis.__agentModules[${jsonEncode(key)}];export default m;${builtins[key]!.map((s) => 'export const $s=m.$s;').join()}')
              .toNativeUtf8()
              .cast();
        }
        final normalized = path.posix.normalize(name.split('?').first);
        if (!path.posix.isWithin(root, normalized)) return nullptr;
        final file = path.posix.relative(normalized, from: root);
        final source = files[file];
        if (source is! String || !file.endsWith('.js')) return nullptr;
        // QuickJS's generic loader does not set import.meta.url. Supplying
        // the virtual URL changes no byte in the imported original source.
        final code =
            'import.meta.url=${jsonEncode('file://$normalized')};\n${utf8.decode(base64Decode(source))}';
        return code.toNativeUtf8().cast();
      } catch (_) {
        return nullptr;
      }
    }
    if (type != qjs.JSChannelType.METHON) return nullptr;
    try {
      _check();
      final data = ptr.cast<Pointer<qjs.JSValue>>();
      final argc = (data + 1).value.cast<Int32>().value;
      if (argc != 1 && argc != 2) throw const AgentException('宿主调用参数无效。');
      final raw = qjs.jsToCString(ctx, (data + 2).value);
      if (raw.length > 36 * 1024 * 1024) throw const AgentException('宿主数据过大。');
      final call = jsonDecode(raw) as List;
      if (call[0] == 'bufferFrom' || call[0] == 'bufferString') {
        try {
          return _binary(
            ctx,
            text(call[0]),
            object(call[1]),
            argc == 2
                ? Pointer.fromAddress(
                    (data + 2).value.address + qjs.sizeOfJSValue,
                  )
                : null,
          );
        } catch (_) {
          final message = qjs.jsEval(
            ctx,
            'new Error("Buffer 编码、类型或大小无效。")',
            '<buffer>',
            0,
          );
          final thrown = qjs.jsThrow(ctx, message);
          qjs.jsFreeValue(ctx, message);
          return thrown;
        }
      }
      final result = _host(text(call[0]), object(call[1]));
      return qjs.jsNewString(ctx, jsonEncode({'ok': true, 'value': result}));
    } catch (e) {
      return qjs.jsNewString(
        ctx,
        jsonEncode({
          'ok': false,
          'error': e is AgentException ? e.message : '扩展宿主操作无效。',
        }),
      );
    }
  }

  Pointer<qjs.JSValue> _binary(
    Pointer<qjs.JSContext> ctx,
    String op,
    Json a,
    Pointer<qjs.JSValue>? value,
  ) {
    final encoding = text(a['encoding']).toLowerCase();
    if (op == 'bufferFrom') {
      final s = text(a['value']);
      final bytes = switch (encoding) {
        'base64' => base64Decode(s),
        'hex' => Uint8List.fromList([
          for (var i = 0; i + 1 < s.length; i += 2)
            int.parse(s.substring(i, i + 2), radix: 16),
        ]),
        'ascii' || 'latin1' || 'binary' => Uint8List.fromList(
          s.codeUnits.map((n) => n & 255).toList(),
        ),
        'utf8' || 'utf-8' || '' => Uint8List.fromList(utf8.encode(s)),
        _ => throw const AgentException('不支持的编码。'),
      };
      if (bytes.length > 12 * 1024 * 1024) {
        throw const AgentException('Buffer 数据过大。');
      }
      final ptr = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
      try {
        ptr.asTypedList(bytes.length).setAll(0, bytes);
        return qjs.jsNewTypedArray(
          ctx,
          ptr,
          bytes.length,
          qjs.JSTypedArrayType.UINT8,
        );
      } finally {
        malloc.free(ptr);
      }
    }
    if (value == null) throw const AgentException('缺少字节数据。');
    final length = calloc<IntPtr>(), type = calloc<Int32>();
    try {
      final ptr = qjs.jsGetTypedArrayData(ctx, value, length, type);
      if (ptr.address == 0 || length.value > 12 * 1024 * 1024) {
        throw const AgentException('字节数据无效。');
      }
      final bytes = ptr.asTypedList(length.value);
      final result = switch (encoding) {
        'base64' => base64Encode(bytes),
        'hex' => bytes.map((n) => n.toRadixString(16).padLeft(2, '0')).join(),
        'ascii' => String.fromCharCodes(bytes.map((b) => b & 127)),
        'latin1' || 'binary' => latin1.decode(bytes),
        'utf8' || 'utf-8' || '' => utf8.decode(bytes, allowMalformed: true),
        _ => throw const AgentException('不支持的编码。'),
      };
      return qjs.jsNewString(ctx, result);
    } finally {
      calloc.free(length);
      calloc.free(type);
    }
  }

  Object? _host(String op, Json a) {
    switch (op) {
      case 'packageInfo':
        return {'id': manifest['id']};
      case 'uuid':
        return const Uuid().v4();
      case 'decodeText':
        final bytes = base64Decode(text(a['data']));
        return switch (text(a['encoding']).toLowerCase()) {
          'ascii' => String.fromCharCodes(bytes.map((b) => b & 127)),
          'binary' || 'latin1' => latin1.decode(bytes),
          'utf8' || 'utf-8' || '' => utf8.decode(bytes, allowMalformed: true),
          _ => throw const AgentException('不支持的文本编码。'),
        };
      case 'hash':
        final algorithm = switch (text(a['algorithm']).toLowerCase()) {
          'sha256' => sha256,
          'sha1' => sha1,
          'md5' => md5,
          _ => throw const AgentException('当前支持 SHA-256、SHA-1 和 MD5 缓存哈希。'),
        };
        return base64Encode(
          algorithm.convert(base64Decode(text(a['data']))).bytes,
        );
      case 'path':
        final parts = strings(a['paths']);
        return switch (a['method']) {
          'normalize' => path.posix.normalize(parts.single),
          'join' => path.posix.joinAll(parts),
          'resolve' => path.posix.normalize(
            path.posix.joinAll(['/data', ...parts]),
          ),
          'dirname' => path.posix.dirname(parts.single),
          'basename' => path.posix.basename(parts.single),
          'extension' => path.posix.extension(parts.single),
          _ => throw const AgentException('不支持的路径操作。'),
        };
      case 'fileURL':
        final u = Uri.parse(text(a['value']));
        if (u.scheme != 'file' || u.host.isNotEmpty) {
          throw const AgentException('只支持包内虚拟 file URL。');
        }
        return u.path;
      case 'url':
        final base = text(a['base']);
        final u = base.isEmpty
            ? Uri.parse(text(a['value']))
            : Uri.parse(base).resolve(text(a['value']));
        if (!u.hasScheme) throw const AgentException('URL 缺少协议。');
        return {
          'href': u.toString(),
          'protocol': '${u.scheme}:',
          'host': u.hasPort ? '${u.host}:${u.port}' : u.host,
          'hostname': u.host,
          'port': u.hasPort ? '${u.port}' : '',
          'origin': u.isScheme('http') || u.isScheme('https')
              ? u.origin
              : 'null',
          'pathname': u.path,
          'search': u.hasQuery ? '?${u.query}' : '',
          'hash': u.hasFragment ? '#${u.fragment}' : '',
          'username': u.userInfo.split(':').first,
          'password': u.userInfo.contains(':')
              ? u.userInfo.split(':').skip(1).join(':')
              : '',
        };
      case 'fs':
        return _fs(a);
      case 'log':
        if (_logs.length < 8) _logs.add(clipped(text(a['text']), 300));
        if (operation == 'session' && hostCall != null) {
          unawaited(
            hostCall!('log', {
              'text': clipped(text(a['text']), 500),
              'level': text(a['level']).isEmpty ? 'info' : text(a['level']),
            }).then<void>((_) {}, onError: (Object _) {}),
          );
        }
        return null;
      case 'abort':
        _requests[integer(a['id'], 0)]?.cancel();
        return null;
      case 'request':
        if (operation == 'inspect') {
          throw const AgentException('导入检查不执行网络请求或发送消息。');
        }
        final service = text(a['operation']);
        final control = {'nextJob', 'jobDone', 'socketNext'}.contains(service);
        if (operation == 'session' &&
            DateTime.now().difference(_requestWindow).inSeconds >= 60) {
          _requestWindow = DateTime.now();
          _calls = 0;
          _bytes = 0;
        }
        if ((!control && ++_calls > (operation == 'session' ? 64 : 24)) ||
            _requests.length >= 6) {
          throw const AgentException('扩展请求次数超过上限。');
        }
        final id = ++_serial;
        final token = CancelToken();
        _requests[id] = token;
        unawaited(
          _request(text(a['operation']), object(a['args']), token).then<void>(
            (value) => _settle(id, value, null),
            onError: (Object e) =>
                _settle(id, null, e is AgentException ? e.message : '请求未能完成。'),
          ),
        );
        return id;
      default:
        throw const AgentException('未开放此宿主能力。');
    }
  }

  String _file(String name, {bool write = false}) {
    if (name.contains('\u0000') || name.contains('\\') || name.contains(':')) {
      throw const AgentException('文件路径无效。');
    }
    final p = path.posix.normalize(path.posix.join('/data', name));
    if ((p == root || path.posix.isWithin(root, p)) && !write) return p;
    if (p == '/data' ||
        path.posix.isWithin('/data', p) ||
        p == '/tmp' ||
        path.posix.isWithin('/tmp', p)) {
      return p;
    }
    throw const AgentException('扩展只能访问自身文件和隔离的数据目录。');
  }

  String _read(String p) {
    if (p == '/data/config.json' && _hostInput['coreConfig'] is Map) {
      return base64Encode(utf8.encode(jsonEncode(_hostInput['coreConfig'])));
    }
    if (p == '/data/session-index-cache.json') {
      return base64Encode(
        utf8.encode(
          jsonEncode({'entries': _hostInput['ledger'] as List? ?? []}),
        ),
      );
    }
    if (p.startsWith('/data/sessions/')) {
      final row = (_hostInput['ledger'] as List? ?? [])
          .map(object)
          .where((r) => '/data/sessions/${r['id']}.json' == p)
          .firstOrNull;
      if (row != null) return base64Encode(utf8.encode(jsonEncode(row)));
    }
    if (path.posix.isWithin(root, p)) {
      final v = files[path.posix.relative(p, from: root)];
      if (v is String) return v;
    }
    final v = object(volume[p])['data'];
    if (v is String) return v;
    throw const AgentException('扩展文件不存在。');
  }

  List<String> _list(String dir) {
    final keys = <String>[
      ...files.keys.map((p) => '$root/$p'),
      ...volume.keys,
      ..._directories,
      if (_hostInput['coreConfig'] is Map) '/data/config.json',
      '/data/session-index-cache.json',
      for (final row in (_hostInput['ledger'] as List? ?? []).map(object))
        '/data/sessions/${row['id']}.json',
    ];
    return keys
        .where((p) => path.posix.isWithin(dir, p))
        .map((p) => path.posix.relative(p, from: dir).split('/').first)
        .toSet()
        .toList()
      ..sort();
  }

  Object? _fs(Json a) {
    final method = text(a['method']);
    final p = _file(
      text(a['file']),
      write: {'write', 'mkdir', 'unlink', 'rename'}.contains(method),
    );
    if ({'write', 'mkdir', 'unlink', 'rename'}.contains(method) &&
        (p == '/data/config.json' ||
            p == '/data/session-index-cache.json' ||
            p.startsWith('/data/sessions/'))) {
      throw const AgentException('宿主配置和费用账本为只读。');
    }
    switch (method) {
      case 'read':
        return _read(p);
      case 'write':
        final data = text(a['data']);
        if (data.length > 16 * 1024 * 1024) {
          throw const AgentException('单个扩展文件过大。');
        }
        base64Decode(data); // validates encoding without accepting objects
        final size = volume.entries
            .where((e) => e.key != p)
            .fold<int>(
              data.length,
              (n, e) => n + text(object(e.value)['data']).length,
            );
        if (size > 40 * 1024 * 1024 ||
            volume.length >= 180 && !volume.containsKey(p)) {
          throw const AgentException('扩展数据空间已满（30 MB / 180 个文件）。');
        }
        volume[p] = {
          'data': data,
          'mtime': DateTime.now().millisecondsSinceEpoch,
        };
        dirty = true;
        _revision++;
        return null;
      case 'mkdir':
        _directories.add(p);
        return null;
      case 'list':
        return _list(p);
      case 'exists':
        try {
          _read(p);
          return true;
        } catch (_) {
          return _directories.contains(p) || _list(p).isNotEmpty;
        }
      case 'stat':
        try {
          final d = _read(p);
          return {
            'size': base64Decode(d).length,
            'mtimeMs': integer(object(volume[p])['mtime'], 0),
            'directory': false,
          };
        } catch (_) {
          if (_directories.contains(p) || _list(p).isNotEmpty) {
            return {'size': 0, 'mtimeMs': 0, 'directory': true};
          }
          rethrow;
        }
      case 'unlink':
        volume.remove(p);
        dirty = true;
        _revision++;
        return null;
      case 'rename':
        final dest = _file(text(a['dest']), write: true);
        if (dest == '/data/config.json' ||
            dest == '/data/session-index-cache.json' ||
            dest.startsWith('/data/sessions/')) {
          throw const AgentException('宿主配置和费用账本为只读。');
        }
        if (!volume.containsKey(p)) throw const AgentException('待重命名文件不存在。');
        volume[dest] = volume.remove(p);
        dirty = true;
        _revision++;
        return null;
      default:
        throw const AgentException('不支持此文件操作。');
    }
  }

  Future<Object?> _request(String op, Json a, CancelToken token) async {
    _check();
    switch (op) {
      case 'socketOpen':
        if (!permissions.contains('web_fetch') &&
            !strings(
              object(manifest['compatibility'])['requirements'],
            ).contains('websocket')) {
          throw const AgentException('此安装包未声明公共 WSS 网络能力。');
        }
        final uri = Uri.tryParse(text(a['url']));
        final headers = object(
          a['headers'],
        ).map((k, v) => MapEntry(k, text(v)));
        if (uri == null ||
            uri.scheme != 'wss' ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment ||
            headers.length > 6 ||
            headers.entries.any(
              (e) =>
                  !{
                    'origin',
                    'user-agent',
                    'accept-language',
                  }.contains(e.key.toLowerCase()) ||
                  e.value.length > 1000 ||
                  e.value.contains(RegExp(r'[\r\n]')),
            )) {
          throw const AgentException('语音连接地址或请求头无效。');
        }
        return socketCall(op, a);
      case 'socketNext':
      case 'socketSend':
      case 'socketClose':
        return socketCall(op, a);
      case 'nextJob':
        if (operation != 'session' || hostCall == null) {
          throw const AgentException('此运行时不接受会话任务。');
        }
        _logs.clear();
        final job = object(await hostCall!('nextJob', {}));
        _hostInput = object(job['input']);
        return job;
      case 'jobDone':
        if (operation != 'session' || hostCall == null) {
          throw const AgentException('此运行时不接受会话任务。');
        }
        final revision = _revision;
        await hostCall!('jobDone', {
          ...a,
          if (dirty) 'volume': volume,
          'dirty': dirty,
        });
        if (revision == _revision) dirty = false;
        return null;
      case 'host':
        if (hostCall == null) throw const AgentException('插件宿主接口不可用。');
        return hostCall!(text(a['operation']), object(a['args']));
      case 'fetch':
        if (!permissions.contains('web_fetch') &&
            !strings(
              object(manifest['compatibility'])['requirements'],
            ).contains('publicFetch')) {
          throw const AgentException('此安装包未声明 web_fetch 权限。');
        }
        final uri = httpEndpoint(text(a['url']));
        if (uri.host == 'qqm-onebot.invalid' && uri.scheme == 'http') {
          if (uri.path != '/ocr_image' ||
              a['method'] != 'POST' ||
              hostCall == null) {
            throw const AgentException('此虚拟协议接口不可用。');
          }
          final args = object(jsonDecode(text(a['body'])));
          final value = await hostCall!('onebot', {
            'action': 'ocr_image',
            'params': args,
          });
          final data = object(value);
          if (data['retcode'] != null && integer(data['retcode'], 0) != 0) {
            throw const AgentException('协议端拒绝了 OCR 请求。');
          }
          final recognized = value is String
              ? value
              : data['text'] is String
              ? text(data['text'])
              : data['result'] is String
              ? text(data['result'])
              : (data['texts'] as List? ?? [])
                    .map((row) => text(object(row)['text']))
                    .where((line) => line.isNotEmpty)
                    .join('\n');
          return {
            'status': 200,
            'headers': {'content-type': 'application/json'},
            'url': uri.toString(),
            'data': base64Encode(
              utf8.encode(
                jsonEncode({
                  'status': 'ok',
                  'retcode': 0,
                  'data': {'text': clipped(recognized, 20000)},
                }),
              ),
            ),
          };
        }
        if (uri.scheme != 'https') {
          throw const AgentException('JavaScript 网络请求只允许 HTTPS。');
        }
        final headers = object(
          a['headers'],
        ).map((k, v) => MapEntry(k, text(v)));
        final apiKey = text(settings['apiKey']);
        final cookieDomains = <String, List<String>>{
          'bilibiliCookie': ['bilibili.com'],
          'douyinCookie': ['douyin.com', 'iesdouyin.com'],
          'tiebaCookie': ['tieba.baidu.com'],
        };
        bool cookieAllowed(String value) => cookieDomains.entries.any(
          (entry) =>
              text(settings[entry.key]).trim().isNotEmpty &&
              value == text(settings[entry.key]).trim() &&
              entry.value.any(
                (domain) => uri.host == domain || uri.host.endsWith('.$domain'),
              ),
        );
        final authOrigins = [settings['baseOrigin'], settings['balanceUrl']]
            .whereType<String>()
            .map(Uri.tryParse)
            .whereType<Uri>()
            .where(
              (u) =>
                  u.scheme == 'https' &&
                  u.host.isNotEmpty &&
                  u.userInfo.isEmpty,
            )
            .map((u) => u.origin)
            .toSet();
        if (headers.length > 20 ||
            headers.entries.any(
              (e) =>
                  !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(e.key) ||
                  e.value.contains(RegExp(r'[\r\n]')) ||
                  (e.key.toLowerCase() == 'authorization' &&
                      !(apiKey.isNotEmpty &&
                          authOrigins.contains(uri.origin) &&
                          (e.value == apiKey ||
                              e.value == 'Bearer $apiKey'))) ||
                  (e.key.toLowerCase() == 'cookie' &&
                      !cookieAllowed(e.value)) ||
                  {
                    'host',
                    'connection',
                    'content-length',
                  }.contains(e.key.toLowerCase()),
            )) {
          throw const AgentException('扩展请求头无效或包含不允许的鉴权头。');
        }
        if (!{'GET', 'POST', 'HEAD'}.contains(a['method'])) {
          throw const AgentException('网络请求方式不支持。');
        }
        final r = await http.fetchBytes(
          uri,
          method: text(a['method']),
          headers: headers,
          body: object(a['body'])['__qqmBinary'] == true
              ? Uint8List.fromList(
                  base64Decode(text(object(a['body'])['data'])),
                )
              : a['body'],
          cancel: token,
          timeoutSeconds: integer(settings['timeoutSec'], 15).clamp(1, 120),
        );
        _check();
        _bytes += r.bytes.length;
        if (_bytes > 24 * 1024 * 1024) {
          throw const AgentException('本轮扩展下载总量超过 24 MB。');
        }
        return {
          'status': r.status,
          'headers': r.headers,
          'url': uri.toString(),
          'data': base64Encode(r.bytes),
        };
      case 'sendImage':
        if (sendImage == null) throw const AgentException('当前上下文不能发送图片。');
        final p = _file(text(a['file']));
        final bytes = base64Decode(_read(p));
        if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
          throw const AgentException('图片需要在 5 MB 以内。');
        }
        _check();
        return await sendImage!(bytes, path.posix.basename(p));
      case 'sendText':
        if (hostCall != null && a['chatKey'] != null) {
          return hostCall!('sendText', a);
        }
        if (sendText == null) throw const AgentException('当前上下文不能发送消息。');
        return await sendText!(text(a['text']));
      case 'sendMedia':
        if (a['type'] != 'record') {
          throw const AgentException('当前仅支持发送语音媒体。');
        }
        final mediaFile = text(a['file']);
        if (mediaFile.startsWith('https://')) {
          if (hostCall == null) {
            throw const AgentException('当前上下文没有 URL 语音发送通道。');
          }
          _check();
          return hostCall!('sendMediaUrl', {
            'url': mediaFile,
            'chatKey': text(a['chatKey']),
          });
        }
        if (sendMedia == null) throw const AgentException('当前上下文不能发送语音。');
        final audio = AgentAudio(
          Uint8List.fromList(base64Decode(_read(_file(text(a['file']))))),
        );
        _check();
        final receipt = await sendMedia!(audio.bytes, audio.name, 'record');
        // The protocol has consumed the bytes, so a package's delayed unlink
        // timer need not keep a permanent audio file or an invocation alive.
        final source = _file(text(a['file']));
        if (source.startsWith('/tmp/')) {
          volume.remove(source);
          dirty = true;
          _revision++;
        }
        return receipt;
      default:
        throw const AgentException('未开放此异步能力。');
    }
  }

  Future<void> _checkpoint() async {
    if (hostCall == null || !active()) return;
    final revision = _revision;
    try {
      await hostCall!('checkpoint', {'dirty': dirty, 'volume': volume});
      if (revision == _revision) dirty = false;
    } catch (_) {
      /* teardown may close an in-flight checkpoint */
    }
  }

  void _settle(int id, Object? value, String? error) {
    wake.pulse();
    _requests.remove(id);
    if (_disposed || !active()) return;
    try {
      _eval(
        'globalThis.__agent.settle($id,${jsonEncode(value)},${jsonEncode(error)});',
      );
    } catch (_) {
      /* run() reports evaluation/timeout errors on the next poll */
    }
  }

  void close() {
    if (_disposed) return;
    _disposed = true;
    for (final c in _requests.values) {
      c.cancel();
    }
    _requests.clear();
    if (_context != null) qjs.jsFreeContext(_context!);
    if (_runtime != null) qjs.jsFreeRuntime(_runtime!);
    _context = null;
    _runtime = null;
    _port.close();
  }
}
