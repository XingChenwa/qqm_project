import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:uuid/uuid.dart';
import 'models.dart';

abstract class AgentTransport {
  void Function(Json event)? onEvent;
  void Function()? onState;
  void Function(String level, String message)? onDiagnostic;
  bool get connected;
  String get status;
  String get nickname;
  Future<void> start();
  Future<void> stop();
  Future<dynamic> call(String action, [Json params = const {}]);

  /// Null for protocols without QQBot's bounded passive reply allowance.
  int? replyCapacity(String kind, String peerId, String triggerId) => null;
  Future<Json> loadOfficialProfile(
    String kind,
    String peerId, {
    String memberId = '',
    String lookupId = '',
    bool force = false,
  }) async => {};
}

class OneBotTransport extends AgentTransport {
  final AgentConnection config;
  final Duration callTimeout;
  HttpServer? _server;
  final _dialClients = <_WsHttpClient>{};
  _Peer? _api, _event;
  final _peers = <_Peer>{};
  final _pending = <String, ({Completer<dynamic> result, _Peer peer})>{};
  final _buffer = <Json>[];
  Timer? _retry;
  int _generation = 0, _attempt = 0;
  bool _stopped = true, _ready = false;
  String _status = '未连接', _nickname = '';
  OneBotTransport(
    this.config, {
    this.callTimeout = const Duration(seconds: 20),
  });
  @override
  bool get connected => _ready && _api != null && _event != null;
  @override
  String get status => _status;
  @override
  String get nickname => _nickname;
  int? get listeningPort => _server?.port;

  void _state(String value) {
    _status = value;
    onState?.call();
  }

  @override
  Future<void> start() async {
    if (!_stopped) return;
    config.validate();
    _stopped = false;
    final generation = ++_generation;
    if (config.mode == 'forward') {
      await _connect(generation);
    } else {
      try {
        final server = await HttpServer.bind(config.host, config.port);
        if (_stopped || generation != _generation) {
          await server.close(force: true);
          return;
        }
        _server = server;
        _state('监听中 · 等待协议端');
        server.listen(
          (r) => unawaited(_accept(r, generation)),
          onError: (Object _) {
            if (!_stopped) _state('监听异常，请重新启动连接');
          },
        );
      } catch (_) {
        _stopped = true;
        _state('监听失败，请检查端口占用和监听地址');
        throw const AgentException('WS 服务未能启动，请检查端口占用和监听地址。');
      }
    }
  }

  Future<void> _connect(int generation) async {
    if (_stopped || generation != _generation) return;
    _state(_attempt == 0 ? '正在连接' : '正在重连');
    final client = _WsHttpClient();
    _dialClients.add(client);
    try {
      final socket =
          await WebSocket.connect(
            config.url,
            customClient: client,
            headers: {
              if (config.token.isNotEmpty)
                'Authorization': 'Bearer ${config.token}',
            },
          ).timeout(
            const Duration(seconds: 12),
            onTimeout: () => throw const AgentException('WS 连接超时'),
          );
      if (_stopped || generation != _generation) {
        await socket.close();
        return;
      }
      _attach(socket, 'Universal', generation);
    } catch (_) {
      if (_stopped || generation != _generation) return;
      _state('连接失败 · 将自动重试，请检查地址与令牌');
      _scheduleRetry(generation);
    } finally {
      _dialClients.remove(client);
      client.close(force: true);
    }
  }

  bool _tokenMatches(String supplied) {
    final a = utf8.encode(config.token), b = utf8.encode(supplied);
    var mismatch = a.length ^ b.length;
    for (var i = 0; i < a.length; i++) {
      mismatch |= a[i] ^ (i < b.length ? b[i] : 0);
    }
    return mismatch == 0;
  }

  Future<void> _accept(HttpRequest request, int generation) async {
    try {
      final auth = request.headers.value('authorization') ?? '';
      final supplied = auth.startsWith('Bearer ') ? auth.substring(7) : '';
      if (_stopped || generation != _generation) {
        request.response.statusCode = 503;
      } else if (request.headers.value('origin') != null ||
          !_tokenMatches(supplied)) {
        request.response.statusCode = 401;
      } else if (request.headers.value('x-self-id') != config.selfId) {
        request.response.statusCode = 403;
      } else {
        final path = request.uri.path;
        final role = request.headers.value('x-client-role') ?? 'Universal';
        final matches =
            path == config.path ||
            role == 'API' &&
                path == '${config.path == '/' ? '' : config.path}/api' ||
            role == 'Event' &&
                path == '${config.path == '/' ? '' : config.path}/event';
        if (!matches ||
            !{'Universal', 'API', 'Event'}.contains(role) ||
            request.uri.query.isNotEmpty ||
            !WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = 400;
        } else {
          final socket = await WebSocketTransformer.upgrade(request);
          if (_stopped || generation != _generation) {
            await socket.close();
            return;
          }
          _attach(socket, role, generation);
          return;
        }
      }
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void _attach(WebSocket socket, String role, int generation) {
    final peer = _Peer(socket, role);
    // API and Event peers belong to the same explicitly pinned QQ account.
    final replaced = <_Peer>{
      if (role != 'Event' && _api != null) _api!,
      if (role != 'API' && _event != null) _event!,
    };
    for (final old in replaced) {
      _drop(old, generation);
      unawaited(old.socket.close());
    }
    _peers.add(peer);
    if (role != 'Event') {
      _api = peer;
      _ready = false;
    }
    if (role != 'API') _event = peer;
    socket.pingInterval = const Duration(seconds: 25);
    socket.listen(
      (raw) => _receive(peer, raw, generation),
      onError: (Object _) => _drop(peer, generation),
      onDone: () => _drop(peer, generation),
      cancelOnError: true,
    );
    if (role != 'Event') {
      unawaited(_verify(peer, generation));
    } else {
      _announceReady();
    }
  }

  Future<void> _verify(_Peer peer, int generation) async {
    try {
      final result = object(await _request(peer, 'get_login_info', {}));
      if (_stopped || generation != _generation || _api != peer) return;
      if (text(result['user_id']) != config.selfId) {
        _state('账号不一致 · 请核对机器人 QQ 号');
        _drop(peer, generation, reason: '账号校验失败');
        await peer.socket.close(1008, 'account mismatch');
        return;
      }
      _nickname = text(result['nickname']);
      _ready = true;
      _attempt = 0;
      _announceReady();
    } catch (_) {
      if (_api == peer) {
        _drop(peer, generation, reason: '账号校验失败，请检查协议端登录状态');
        await peer.socket.close();
      }
    }
  }

  void _announceReady() {
    if (connected) {
      _state('已连接');
      final events = List<Json>.of(_buffer);
      _buffer.clear();
      for (final event in events) {
        onEvent?.call(event);
      }
    } else {
      _state('等待 API / 事件连接');
    }
  }

  void _receive(_Peer peer, dynamic raw, int generation) {
    if (_stopped || generation != _generation || !_peers.contains(peer)) return;
    try {
      if (raw is! String || raw.length > 2 * 1024 * 1024) {
        unawaited(peer.socket.close(1009, 'frame limit'));
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final value = object(decoded);
      if (value['echo'] != null && value['post_type'] == null) {
        final echo = text(value['echo']);
        final pending = _pending[echo];
        if (pending == null || pending.peer != peer) return;
        _pending.remove(echo);
        if (value['status'] == 'ok' && integer(value['retcode'], -1) == 0) {
          pending.result.complete(value['data']);
        } else {
          pending.result.completeError(
            AgentException(
              'OneBot 操作失败（错误码 ${integer(value['retcode'], -1)}），请检查协议端权限与状态。',
            ),
          );
        }
        return;
      }
      if (peer != _event || text(value['self_id']) != config.selfId) return;
      if (value['post_type'] == 'meta_event') return;
      if (connected) {
        onEvent?.call(value);
      } else if (_buffer.length < 32) {
        _buffer.add(value);
      }
    } catch (_) {
      // Never include a malformed frame (or any credentials) in diagnostics.
    }
  }

  @override
  Future<dynamic> call(String action, [Json params = const {}]) {
    if (!connected) throw const AgentException('OneBot 尚未连接。');
    return _request(_api!, action, params);
  }

  Future<dynamic> _request(_Peer peer, String action, Json params) async {
    if (_pending.length >= 32) throw const AgentException('OneBot 请求繁忙，请稍后重试。');
    final echo = const Uuid().v4();
    final result = Completer<dynamic>();
    _pending[echo] = (result: result, peer: peer);
    try {
      peer.socket.add(
        jsonEncode({'action': action, 'params': params, 'echo': echo}),
      );
      return await result.future.timeout(callTimeout);
    } on TimeoutException {
      throw const AgentException('OneBot 回执超时；发送结果未知，请先核对聊天记录，避免重复发送。');
    } finally {
      _pending.remove(echo);
    }
  }

  void _drop(_Peer peer, int generation, {String reason = '连接已断开'}) {
    if (!_peers.remove(peer)) return;
    if (_api == peer) {
      _api = null;
      _ready = false;
    }
    if (_event == peer) _event = null;
    _buffer.clear();
    for (final key in _pending.keys.toList()) {
      final p = _pending[key]!;
      if (p.peer == peer) {
        _pending.remove(key);
        p.result.completeError(const AgentException('连接已断开，未确认的消息不会自动重发。'));
      }
    }
    if (!_stopped && generation == _generation) {
      _state(config.mode == 'reverse' ? '$reason · 等待协议端重连' : reason);
      if (config.mode == 'forward') _scheduleRetry(generation);
    }
  }

  void _scheduleRetry(int generation) {
    if (_retry != null || _stopped) return;
    final seconds = min(30, 2 * pow(2, min(_attempt++, 4)).toInt());
    _retry = Timer(Duration(seconds: seconds), () {
      _retry = null;
      unawaited(_connect(generation));
    });
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    ++_generation;
    _retry?.cancel();
    _retry = null;
    _ready = false;
    _buffer.clear();
    for (final client in _dialClients.toList()) {
      client.close(force: true);
    }
    _dialClients.clear();
    for (final peer in _peers.toList()) {
      _drop(peer, _generation);
      unawaited(peer.socket.close());
    }
    final server = _server;
    _server = null;
    await server?.close(force: true);
    _api = null;
    _event = null;
    _state('未连接');
  }
}

class _Peer {
  final WebSocket socket;
  final String role;
  _Peer(this.socket, this.role);
}

/// The SDK WebSocket dialer uses openUrl. Keep handshake cancellation and
/// disable redirects, so a remote redirect cannot forward the access token.
class _WsHttpClient implements HttpClient {
  final HttpClient _delegate = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await _delegate.openUrl(method, url);
    request.followRedirects = false;
    return request;
  }

  @override
  void close({bool force = false}) => _delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
