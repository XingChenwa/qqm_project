import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'websocket_service.dart';

/// The two workspaces keep separate models/stores, but one official bot needs
/// only one physical gateway. A lease owns its subscription, never its peers.
String officialQqScope(String appId, String apiBase) =>
    jsonEncode([appId, apiBase.replaceFirst(RegExp(r'/+$'), '')]);

class OfficialQqGatewayPool {
  static final shared = OfficialQqGatewayPool();
  final WebSocketService Function() _factory;
  final _sessions = <String, _SharedGateway>{};
  OfficialQqGatewayPool({WebSocketService Function()? factory})
    : _factory = factory ?? WebSocketService.new;

  WebSocketService client({required String Function() scope}) =>
      _GatewayLease(this, scope);

  void _release(_GatewayLease lease) {
    final session = lease._session;
    lease._session = null;
    if (session == null) return;
    session.members.remove(lease);
    if (session.members.isEmpty) {
      if (identical(_sessions[session.key], session)) {
        _sessions.remove(session.key);
      }
      session.close();
    } else {
      session.policy();
    }
  }
}

Object? _copy(Object? value) => value is Map
    ? value.map((k, v) => MapEntry(k.toString(), _copy(v)))
    : value is List
    ? value.map(_copy).toList()
    : value;
Map<String, dynamic> _event(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(_copy(value) as Map);

class _SharedGateway {
  static final _log = Logger('SharedQqGateway');
  final String key;
  final WebSocketService socket;
  final members = <_GatewayLease>{};
  late final StreamSubscription<Map<String, dynamic>> subscription;
  final states = StreamController<void>.broadcast();
  Future<bool>? opening;
  Future<void>? recovering;
  Map<String, dynamic>? ready;
  int? hello;
  bool closed = false;

  _SharedGateway(this.key, this.socket) {
    socket.onConnectionStateChanged = (label) {
      _each((lease) => lease.onConnectionStateChanged?.call(label));
      if (!closed) states.add(null);
    };
    socket.onReady = (data) {
      ready = _event(data);
      _each((lease) => lease.onReady?.call(_event(data)));
    };
    socket.onDispatch = (type, data) =>
        _each((lease) => lease.onDispatch?.call(type, _event(data)));
    socket.onHello = (interval) {
      hello = interval;
      _each((lease) => lease.onHello?.call(interval));
    };
    socket.onHeartbeatAck = () =>
        _each((lease) => lease.onHeartbeatAck?.call());
    socket.refreshAccessToken = () async {
      for (final lease in members.toList().reversed) {
        try {
          final token = await lease.refreshAccessToken?.call();
          if (!closed && members.contains(lease) && token?.isNotEmpty == true) {
            return token;
          }
        } catch (_) {
          // Try the other live workspace; never log credentials or HTTP bodies.
        }
      }
      return null;
    };
    subscription = socket.messageStream.listen((data) {
      if (data['_transportGeneration'] != null &&
          data['_transportGeneration'] != socket.transportGeneration) {
        return;
      }
      _each((lease) {
        if (!lease._events.hasListener) return;
        lease._events.add({
          ..._event(data),
          '_transportGeneration': lease.transportGeneration,
        });
      });
    });
  }

  void _each(void Function(_GatewayLease) action) {
    for (final lease in members.toList()) {
      if (closed || lease._closed || !identical(lease._session, this)) continue;
      try {
        action(lease);
      } catch (_) {
        _log.warning('QQ 网关订阅处理失败，其他工作区继续接收。');
      }
    }
  }

  bool get reconnect => members.any((lease) => lease._autoReconnect);
  Duration get interval =>
      members.map((lease) => lease._interval).reduce((a, b) => a < b ? a : b);
  void policy() => socket.updateReconnectPolicy(
    autoReconnect: reconnect,
    reconnectInterval: interval,
  );

  Future<bool> connect(String url, String token) async {
    if (socket.isConnected) return true;
    final current = opening;
    if (current != null) return current;
    if (socket.connectionRequested) {
      try {
        await states.stream
            .firstWhere((_) => socket.isConnected)
            .timeout(const Duration(seconds: 30));
        return !closed && socket.isConnected;
      } catch (_) {
        return false;
      }
    }
    ready = null;
    final pending = socket.connect(
      wsUrl: url,
      accessToken: token,
      autoReconnect: reconnect,
      reconnectInterval: interval,
    );
    opening = pending;
    try {
      return await pending;
    } finally {
      if (identical(opening, pending)) opening = null;
    }
  }

  Future<void> recover() async {
    final current = recovering;
    if (current != null) return current;
    final work = socket.recoverAfterResume();
    recovering = work;
    try {
      await work;
    } finally {
      if (identical(recovering, work)) recovering = null;
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    unawaited(subscription.cancel());
    socket.dispose();
    unawaited(states.close());
  }
}

class _GatewayLease extends WebSocketService {
  final OfficialQqGatewayPool pool;
  final String Function() scope;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  _SharedGateway? _session;
  bool _closed = false, _autoReconnect = true;
  int _epoch = 0;
  Duration _interval = const Duration(seconds: 5);
  _GatewayLease(this.pool, this.scope);

  @override
  Stream<Map<String, dynamic>> get messageStream => _events.stream;
  @override
  ConnectionState get state =>
      _session?.socket.state ?? ConnectionState.disconnected;
  @override
  bool get isConnected => !_closed && (_session?.socket.isConnected ?? false);
  @override
  bool get connectionRequested =>
      !_closed && (_session?.socket.connectionRequested ?? false);
  @override
  String get lastError => _session?.socket.lastError ?? '';
  @override
  int get transportGeneration =>
      _epoch * 1000000 + (_session?.socket.transportGeneration ?? 0);
  @override
  void updateAccessToken(String token) =>
      _session?.socket.updateAccessToken(token);
  @override
  Future<void> recoverAfterResume() async => _session?.recover();

  @override
  Future<bool> connect({
    required String wsUrl,
    required String accessToken,
    bool autoReconnect = true,
    Duration reconnectInterval = const Duration(seconds: 5),
  }) async {
    if (_closed) return false;
    final key = scope();
    _autoReconnect = autoReconnect;
    _interval = reconnectInterval;
    if (_session?.key == key) {
      _session!.policy();
      return _session!.connect(wsUrl, accessToken);
    }
    pool._release(this);
    _epoch++;
    final session = pool._sessions.putIfAbsent(
      key,
      () => _SharedGateway(key, pool._factory()),
    );
    _session = session;
    session.members.add(this);
    if (session.members.length > 1) session.policy();
    if (session.socket.isConnected) {
      onConnectionStateChanged?.call('在线');
      if (session.hello != null) onHello?.call(session.hello!);
      if (session.ready != null) onReady?.call(_event(session.ready!));
    }
    final success = await session.connect(wsUrl, accessToken);
    return !_closed && identical(_session, session) && success;
  }

  @override
  void disconnect() {
    if (_closed) return;
    pool._release(this);
    _epoch++;
    onConnectionStateChanged?.call('离线');
  }

  @override
  void dispose() {
    if (_closed) return;
    disconnect();
    _closed = true;
    unawaited(_events.close());
    super.dispose();
  }
}
