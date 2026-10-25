import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'package:dio/dio.dart';
import '../runtime/notifier.dart';
import 'models.dart';
import 'store.dart';
import 'onebot.dart';
import 'qqbot.dart';
import 'http.dart';
import 'script.dart';
import 'extensions.dart';
import 'ai.dart';
import 'defaults.dart';
import 'js_packages.dart';
import 'reply_format.dart';
import '../utils/profile_helpers.dart';
import 'message_context.dart';
import 'package_compatibility.dart';
import 'audio.dart';
import 'snapshot_cache.dart';
import 'redaction.dart';
part 'runtime_services.dart';

/// Application composition root. Does not import any official-bot service.
class AgentController extends ChangeNotifier {
  final AgentStore store;
  final AgentTransport Function(AgentConnection)? transportFactory;
  void Function(AgentConnection)? beforeConnect;
  final AgentHttp http;
  final AgentScripts scripts;
  late final AgentExtensions extensionRunner;
  late final AgentJsPackages packages;
  late final AgentAi ai;
  AgentController({
    AgentStore? store,
    AgentModel? model,
    AgentHttp? http,
    this.transportFactory,
  }) : store = store ?? AgentStore(),
       http = http ?? AgentHttp(),
       scripts = AgentScripts() {
    packages = AgentJsPackages(this.store, this.http);
    extensionRunner = AgentExtensions(this.http, scripts, packages: packages);
    ai = AgentAi(model ?? CompatibleAgentModel(this.http), extensionRunner);
  }
  bool ready = false, _closed = false;
  Future<void>? _opening;
  final _transports = <String, AgentTransport>{};
  final _epochs = <String, int>{}, _sessionEpochs = <String, int>{};
  final _turns = <String, AgentTurn>{};
  final _queues = <String, Future<void>>{};
  final _ingest = <String, Future<void>>{};
  final _ingestCounts = <String, int>{};
  final _lastTrigger = <String, DateTime>{};
  final _logs = <Json>[];
  final _replyStates = <String, Json>{};
  final _profileJobs = <String, Future<void>>{};
  final _decisionLogged = <String, DateTime>{};
  final _usageRunIds = <String, String>{};
  final _burstWindows = <String, _AgentBurstWindow>{};
  final _batchContexts = <String, List<AgentMessage>>{};
  final _connectionCache = AgentSnapshotCache<AgentConnection>();
  final _providerCache = AgentSnapshotCache<AgentProvider>();
  final _presetCache = AgentSnapshotCache<AgentPreset>();
  final _extensionCache = AgentSnapshotCache<AgentExtension>();
  Timer? _notification;
  int _revision = 0, _queued = 0, _activeAi = 0;
  final _permits = <Completer<void>>[];
  final _cancelTests = <CancelToken>{};
  int get revision => _revision;
  List<AgentConnection> get connections =>
      _connectionCache.read(store, 'connection', AgentConnection.fromJson);
  List<AgentProvider> get providers =>
      _providerCache.read(store, 'provider', AgentProvider.fromJson);
  List<AgentPreset> get presets =>
      _presetCache.read(store, 'preset', AgentPreset.fromJson);
  List<AgentExtension> get extensions =>
      _extensionCache.read(store, 'extension', (value) {
        final e = AgentExtension.fromJson(value);
        return AgentExtension(
          readOnlyAgentJson(e.manifest),
          enabled: e.enabled,
          settings: readOnlyAgentJson(e.settings),
          secrets: Map.unmodifiable(e.secrets),
        );
      });
  List<Json> get logs => List.unmodifiable(_logs);
  Json replyState(String key) => object(_replyStates[key]);
  void dismissReplyState(String key) {
    _replyStates.remove(key);
    _changed();
  }

  Set<String> get busySessions => Set.unmodifiable(_turns.keys);
  AgentConnection? connection(String id) =>
      connections.where((p) => p.id == id).firstOrNull;
  AgentSession? session(String key) {
    final value = store.get('session:$key');
    return value == null ? null : AgentSession.fromJson(value);
  }

  List<AgentSession> sessions([String? connectionId]) {
    final result = store.all('session').map(AgentSession.fromJson).where((s) {
      final c = connection(s.connectionId);
      return c != null &&
          c.selfId == s.selfId &&
          c.protocol == s.protocol &&
          (connectionId == null || s.connectionId == connectionId);
    }).toList()..sort((a, b) => b.updated.compareTo(a.updated));
    return result;
  }

  String status(String id) => _transports[id]?.status ?? '未连接';
  String nickname(String id) =>
      text(
        store.get('self-name:$id:${connection(id)?.selfId}')?['name'],
      ).isNotEmpty
      ? text(store.get('self-name:$id:${connection(id)?.selfId}')?['name'])
      : _transports[id]?.nickname ?? '';
  bool connected(String id) => _transports[id]?.connected == true;
  bool started(String id) => _transports.containsKey(id);
  Json get usage =>
      store.get('meta:usage') ?? {'calls': 0, 'input': 0, 'output': 0};

  Future<void> initialize() {
    if (_closed) return Future.error(const AgentException('QQ Agent 已关闭。'));
    return _opening ??= _initialize().catchError((Object e) {
      _opening = null;
      throw const AgentException('QQ Agent 数据未能打开，请检查本地存储权限后重试。官方机器人数据未被修改。');
    });
  }

  Future<void> _initialize() async {
    await store.open();
    if (store.get('meta:initialized') == null) {
      for (final p in agentPresets()) {
        if (store.get('preset:${p.id}') == null) {
          await store.put('preset:${p.id}', p.toJson());
        }
      }
      for (final e in agentExamples()) {
        if (store.get('extension:${e.id}') == null) {
          await store.put('extension:${e.id}', e.toJson());
        }
      }
      await store.put('meta:initialized', {'schema': 1});
    }
    if (_closed) return;
    for (final e in extensions.where(
      (e) =>
          e.isJavaScript &&
          e.compatibility['hostVersion'] != agentPackageHostVersion,
    )) {
      try {
        await saveExtension(e, refresh: true);
      } catch (error) {
        _log('warning', '扩展接口复检未完成：${e.name} · ${describeError(error)}');
      }
    }
    ready = true;
    _changed();
    for (final c in connections.where((c) => c.autoConnect)) {
      unawaited(
        connect(c.id).catchError((Object e) {
          _log('error', describeError(e), c.id);
        }),
      );
    }
  }

  void _changed({bool defer = false}) {
    if (!_closed) {
      _revision++;
      if (defer) {
        _notification ??= Timer(const Duration(milliseconds: 32), () {
          _notification = null;
          if (!_closed) notifyListeners();
        });
        return;
      }
      _notification?.cancel();
      _notification = null;
      notifyListeners();
    }
  }

  String describeError(Object error) {
    var value = error is AgentException ? error.message : '操作未完成，请检查配置或连接状态。';
    for (final secret in [
      ...connections.map((p) => p.token),
      ...connections.map((p) => p.clientSecret),
      ...providers.map((p) => p.apiKey),
      ...extensions.expand((e) => e.secrets.values),
      ...extensions.expand((e) => e.privateSettingValues),
    ].where((s) => s.isNotEmpty)) {
      value = value.replaceAll(secret, '[已隐藏]');
    }
    return clipped(value, 500);
  }

  void _log(
    String level,
    String message, [
    String connectionId = '',
    String sessionKey = '',
    String stage = '',
  ]) {
    if (_closed) return;
    _logs.add({
      'time': DateTime.now().toIso8601String(),
      'level': level,
      'message': describeError(AgentException(message)),
      'connectionId': connectionId,
      'connectionName': connection(connectionId)?.name ?? '',
      if (sessionKey.isNotEmpty) 'sessionKey': sessionKey,
      if (stage.isNotEmpty) 'stage': stage,
    });
    if (_logs.length > 300) _logs.removeAt(0);
    _changed(defer: true);
  }

  void _replyState(
    AgentConnection c,
    AgentSession s,
    String phase,
    String message, {
    bool error = false,
    String messageId = '',
    bool log = true,
  }) {
    _replyStates[s.key] = {
      'phase': phase,
      'message': describeError(AgentException(message)),
      'error': error,
      'messageId': messageId,
      'time': DateTime.now().toIso8601String(),
    };
    if (_replyStates.length > 500) _replyStates.remove(_replyStates.keys.first);
    if (log) {
      _log(error ? 'error' : 'info', message, c.id, s.key, phase);
    } else {
      _changed();
    }
  }

  void _ignored(
    AgentConnection c,
    AgentSession s,
    AgentMessage m,
    String reason,
  ) {
    final key = '${s.key}:$reason',
        last = _decisionLogged[key],
        now = DateTime.now();
    final shouldLog =
        last == null || now.difference(last) > const Duration(seconds: 30);
    if (shouldLog) {
      _decisionLogged[key] = now;
      if (_decisionLogged.length > 500) {
        _decisionLogged.remove(_decisionLogged.keys.first);
      }
      _log('info', '未自动回复：$reason', c.id, s.key, 'decision');
    }
    if (!_queues.containsKey(s.key) && !_turns.containsKey(s.key)) {
      _replyState(
        c,
        s,
        'ignored',
        '未自动回复：$reason',
        messageId: m.id,
        log: false,
      );
    }
  }

  Future<void> saveConnection(AgentConnection profile) async {
    profile.validate();
    if (!presets.any((p) => p.id == profile.presetId)) {
      throw const AgentException('请选择已有 AI 预设。');
    }
    if (!profile.isOfficial &&
        profile.mode == 'reverse' &&
        connections.any(
          (c) =>
              c.id != profile.id &&
              !c.isOfficial &&
              c.mode == 'reverse' &&
              c.port == profile.port,
        )) {
      throw const AgentException('此监听端口已被另一个 Agent 连接使用，请选择不同端口。');
    }
    await disconnect(profile.id);
    await store.put('connection:${profile.id}', profile.toJson());
    _changed();
  }

  Future<void> deleteConnection(String id) async {
    await disconnect(id);
    await store.remove('connection:$id');
    // Historical records retain their original ownership; no reassignment.
    _changed();
  }

  Future<void> saveProvider(AgentProvider value) async {
    value.validate();
    _cancelAll();
    await store.put('provider:${value.id}', value.toJson());
    await _restartRuntimes();
    _changed();
  }

  Future<void> deleteProvider(String id) async {
    if (presets.any(
      (p) => p.providerId == id || p.imageDescriptionProviderId == id,
    )) {
      throw const AgentException('请先修改使用此模型配置的预设。');
    }
    _cancelAll();
    await store.remove('provider:$id');
    _changed();
  }

  Future<void> savePreset(AgentPreset value) async {
    value.validate();
    if (value.providerId.isNotEmpty &&
        !providers.any((p) => p.id == value.providerId)) {
      throw const AgentException('预设指定的模型配置不存在。');
    }
    if (value.imageDescriptionProviderId.isNotEmpty &&
        !providers.any(
          (p) => p.id == value.imageDescriptionProviderId && p.vision,
        )) {
      throw const AgentException('请选择支持图片输入的转述模型；请先在 AI 模型中启用其视觉能力。');
    }
    _cancelAll();
    await store.put('preset:${value.id}', value.toJson());
    await _restartRuntimes();
    _changed();
  }

  Future<void> deletePreset(String id) async {
    if (connections.any((c) => c.presetId == id) ||
        sessions().any((s) => s.presetId == id)) {
      throw const AgentException('请先修改使用此预设的连接或会话。');
    }
    _cancelAll();
    await store.remove('preset:$id');
    _changed();
  }

  Future<void> saveExtension(
    AgentExtension value, {
    bool refresh = false,
  }) async {
    value.validate();
    if (value.isJavaScript) {
      final inspected = await packages.run(
        manifest: value.manifest,
        settings: value.config,
        operation: 'inspect',
        active: () => !_closed,
      );
      final found = object(
        redactAgentValue(inspected, [
          ...value.privateSettingValues,
          ...value.secrets.values,
        ]),
      );
      final tools = (found['tools'] as List? ?? []).map((t) {
        final j = object(t);
        return <String, dynamic>{
          'name': '${value.id}__${j['id']}',
          'description': j['description'],
          'parameters': j['parameters'],
          if (j['requiresMediaAck'] is bool)
            'requiresMediaAck': j['requiresMediaAck'],
          'handler': {'type': 'javascript', 'id': j['id']},
        };
      }).toList();
      final compatibility = packageCompatibility(value.manifest, found);
      value = value.copyWith(
        manifest: {
          ...value.manifest,
          'tools': tools,
          'compatibility': compatibility,
        },
      );
      value.validate();
      if (value.enabled && strings(compatibility['blockers']).isNotEmpty) {
        if (!refresh) {
          throw AgentException(
            '扩展已保留，暂不能启用：${strings(compatibility['blockers']).join('\n')}',
          );
        }
        value = value.copyWith(enabled: false);
        _log(
          'warning',
          '扩展重新检查后暂时关闭：${value.name} · ${strings(compatibility['blockers']).join('；')}',
        );
      }
      if (value.enabled && object(found['available'])['ok'] == false) {
        throw AgentException(
          '请先完善扩展设置：${text(object(found['available'])['reason'])}',
        );
      }
    }
    _cancelAll();
    await store.put('extension:${value.id}', value.toJson());
    await _restartRuntimes();
    _changed();
  }

  Future<void> importPackage(List<int> bytes) async {
    final value = AgentExtension.fromPackage(bytes);
    if (extensions.any((e) => e.id == value.id)) {
      throw const AgentException('同 ID 扩展已存在。请先导出备份，再删除旧包后导入。');
    }
    await saveExtension(value);
  }

  Future<void> importExtension(String source, {String filename = ''}) async {
    final value = AgentExtension.parse(source, filename: filename);
    if (extensions.any((e) => e.id == value.id)) {
      throw const AgentException('同 ID 扩展已存在，请在编辑器修改或先更换 ID。');
    }
    await saveExtension(value);
  }

  Future<void> deleteExtension(String id) async {
    _cancelAll();
    await store.remove('extension:$id');
    for (final key
        in store.keys.where((k) => k.startsWith('js-volume:$id:')).toList()) {
      await store.remove(key);
    }
    await _restartRuntimes();
    _changed();
  }

  Future<void> connect(String id) async {
    final c = connection(id);
    if (c == null) throw const AgentException('连接不存在。');
    if (_transports.containsKey(id)) return;
    c.validate();
    beforeConnect?.call(c);
    if (c.isOfficial &&
        connections.any(
          (p) =>
              p.id != c.id &&
              p.isOfficial &&
              p.selfId == c.selfId &&
              started(p.id),
        )) {
      throw const AgentException('这个 AppID 已有运行中的 Agent 连接，请先停止原连接。');
    }
    final t =
        transportFactory?.call(c) ??
        (c.isOfficial
            ? QqBotAgentTransport(
                c,
                reserveSequence: (messageId, limit) =>
                    store.reserveReplySequence(
                      'qqbot-sequence:${c.selfId}:$messageId',
                      limit,
                    ),
                sequenceUsed: (messageId) => integer(
                  store.get(
                    'qqbot-sequence:${c.selfId}:$messageId',
                  )?['sequence'],
                  0,
                ),
              )
            : OneBotTransport(c));
    _transports[id] = t;
    t.onDiagnostic = (level, message) {
      if (!_closed && identical(_transports[id], t)) {
        _log(level, message, id, '', 'protocol');
      }
    };
    var wasConnected = false;
    t.onState = () {
      if (!identical(_transports[id], t) || _closed) return;
      if (wasConnected && !t.connected) _cancelConnection(id);
      if (!wasConnected && t.connected) unawaited(_activateRuntime(c));
      wasConnected = t.connected;
      _log(
        t.connected ? 'info' : 'warning',
        '连接状态：${t.status}',
        id,
        '',
        'connection',
      );
    };
    t.onEvent = (event) {
      if (_closed || !identical(_transports[id], t)) return;
      final pending = _ingestCounts[id] ?? 0;
      if (pending >= 256) {
        _log('warning', '接收队列已满，本条协议事件未入队', id, '', 'receive');
        return;
      }
      _ingestCounts[id] = pending + 1;
      final epoch = _epochs[id] ?? 0;
      bool current() =>
          !_closed &&
          identical(_transports[id], t) &&
          (_epochs[id] ?? 0) == epoch;
      final previous = _ingest[id] ?? Future<void>.value();
      _ingest[id] = previous
          .then((_) async {
            if (current()) {
              await _receive(c, event, current);
            }
          })
          .catchError((Object e) {
            _log('error', describeError(e), id);
          })
          .whenComplete(() => _ingestCounts[id] = (_ingestCounts[id] ?? 1) - 1);
    };
    try {
      await t.start();
      if (identical(_transports[id], t)) {
        _log('info', '已启动 ${c.protocolLabel} 连接', id);
        unawaited(_activateRuntime(c));
      }
    } catch (e) {
      if (identical(_transports[id], t)) {
        _log('error', '连接启动失败：${describeError(e)}', id, '', 'connection');
        _transports.remove(id);
      }
      await t.stop();
      rethrow;
    }
  }

  Future<void> disconnect(String id) async {
    _cancelConnection(id);
    final t = _transports.remove(id);
    t?.onEvent = null;
    t?.onState = null;
    await t?.stop();
    _changed();
  }

  void _cancelConnection(String id) {
    final c = connection(id);
    if (c != null) unawaited(packages.stopScope(_runtimeScope(c)));
    _epochs[id] = (_epochs[id] ?? 0) + 1;
    for (final entry in _burstWindows.entries.toList()) {
      if (entry.value.connectionId == id) {
        entry.value.timer?.cancel();
        _burstWindows.remove(entry.key);
      }
    }
    for (final s in sessions(id)) {
      ai.clearImageCaptions(sessionKey: s.key);
    }
    for (final entry in _turns.entries.toList()) {
      if (session(entry.key)?.connectionId == id) entry.value.stop();
    }
  }

  void _cancelAll() {
    ai.clearImageCaptions();
    for (final c in connections) {
      _cancelConnection(c.id);
    }
    for (final t in _turns.values) {
      t.stop();
    }
  }

  void stopReply(String key) {
    _burstWindows.remove(key)?.timer?.cancel();
    ai.clearImageCaptions(sessionKey: key);
    _sessionEpochs[key] = (_sessionEpochs[key] ?? 0) + 1;
    _turns[key]?.stop();
    final s = session(key), c = s == null ? null : connection(s.connectionId);
    if (s != null && c != null && _turns.containsKey(key)) {
      _replyState(c, s, 'stopped', '本轮 AI 回复已停止。');
    }
    _changed();
  }

  Future<void> configureSession(AgentSession value) async {
    _validateSession(value);
    if (value.memory.length > 8000) {
      throw const AgentException('会话备注最多 8000 字符。');
    }
    if (value.presetId.isNotEmpty &&
        !presets.any((p) => p.id == value.presetId)) {
      throw const AgentException('指定的预设不存在。');
    }
    stopReply(value.key);
    final old = session(value.key);
    if (old != null) {
      value.updated = old.updated;
      value.unread = old.unread;
      value.nameIsManual = value.name != old.name ? true : old.nameIsManual;
    }
    await store.put('session:${value.key}', value.toJson());
    _changed();
  }

  Future<void> markRead(String key) async {
    final s = session(key);
    if (s == null || s.unread == 0) return;
    s.unread = 0;
    await store.put('session:$key', s.toJson());
    _changed();
  }

  Future<void> clearContext(String key) async {
    if (session(key) == null) return;
    stopReply(key);
    await store.put('context:$key', {
      'afterId': store.messages(key).lastOrNull?.id ?? '',
    });
    _log('info', '已开始新 AI 上下文，保留聊天记录', session(key)!.connectionId);
  }

  Future<void> clearHistory(String key) async {
    stopReply(key);
    await store.remove('history:$key');
    await clearContext(key);
    _changed();
  }

  void _validateSession(AgentSession s) {
    final c = connection(s.connectionId);
    if (c == null ||
        s.selfId != c.selfId ||
        s.protocol != c.protocol ||
        !{'group', 'private'}.contains(s.kind) ||
        !c.acceptsPeer(s.peerId)) {
      throw const AgentException('会话与机器人账号不匹配，请重新选择。');
    }
  }

  Future<AgentSession> openSession(
    String connectionId,
    String kind,
    String peerId, {
    String name = '',
    bool received = false,
  }) async {
    final c = connection(connectionId);
    if (c == null) throw const AgentException('请先添加机器人连接。');
    final value = AgentSession(
      connectionId: c.id,
      selfId: c.selfId,
      protocol: c.protocol,
      kind: kind,
      peerId: peerId,
      name: name.isEmpty ? '${kind == 'group' ? '群' : 'QQ'} $peerId' : name,
      nameIsManual: !received && name.isNotEmpty,
    );
    _validateSession(value);
    final existing = session(value.key);
    if (existing != null) return existing;
    await store.put('session:${value.key}', value.toJson());
    _changed();
    return value;
  }

  Future<void> syncContacts(String id) async {
    if (connection(id)?.isOfficial == true) {
      throw const AgentException('QQBot 没有好友与群列表接口，收到消息后会自动创建 Agent 会话。');
    }
    final t = _transports[id];
    if (t?.connected != true) throw const AgentException('请先连接 OneBot。');
    final epoch = _epochs[id] ?? 0;
    for (final kind in ['private', 'group']) {
      final value = await t!.call(
        kind == 'group' ? 'get_group_list' : 'get_friend_list',
      );
      if (_closed ||
          !identical(_transports[id], t) ||
          epoch != (_epochs[id] ?? 0)) {
        return;
      }
      if (value is! List) continue;
      for (final raw in value.take(1000)) {
        if (_closed ||
            !identical(_transports[id], t) ||
            epoch != (_epochs[id] ?? 0)) {
          return;
        }
        final item = object(raw);
        final peer = text(item[kind == 'group' ? 'group_id' : 'user_id']);
        if (!qqId(peer)) continue;
        final name = text(
          item[kind == 'group' ? 'group_name' : 'remark'],
        ).trim();
        final s = await openSession(
          id,
          kind,
          peer,
          name: name.isEmpty ? text(item['nickname']) : name,
        );
        if (name.isNotEmpty) {
          s.name = name;
          await store.put('session:${s.key}', s.toJson());
        }
      }
    }
    _changed();
  }

  String _profileKey(
    AgentConnection c,
    String kind,
    String peer, [
    String member = '',
  ]) =>
      'official-profile:${base64Url.encode(utf8.encode(jsonEncode([c.id, c.selfId, kind, peer, member])))}';
  String _cachedName(
    AgentConnection c,
    String kind,
    String peer, [
    String member = '',
  ]) => firstProfileName([
    store.get(_profileKey(c, kind, peer, member))?['name'],
  ]);

  Future<void> refreshOfficialProfile(String sessionKey) async {
    final s = session(sessionKey),
        c = s == null ? null : connection(s.connectionId);
    if (s == null || c == null || !c.isOfficial) {
      throw const AgentException('请选择 QQBot 会话。');
    }
    if (!c.resolveOfficialProfiles) {
      throw const AgentException('请先在连接高级设置开启资料同步。');
    }
    final t = _transports[c.id];
    if (t?.connected != true) throw const AgentException('请先启动此 QQBot 连接。');
    final epoch = _epochs[c.id] ?? 0;
    bool current() =>
        !_closed &&
        identical(_transports[c.id], t) &&
        (_epochs[c.id] ?? 0) == epoch;
    if (s.kind == 'group') {
      await _loadProfile(c, s, 'group', current, force: true);
      final sender = store
          .messages(s.key)
          .where((m) => !m.outgoing && !m.senderIsBot)
          .lastOrNull;
      if (sender != null) {
        await _loadProfile(
          c,
          s,
          'member',
          current,
          memberId: sender.senderId,
          force: true,
        );
      }
    } else {
      await _loadProfile(c, s, 'private', current, force: true);
    }
  }

  void _scheduleProfiles(
    AgentConnection c,
    AgentSession s,
    Json event,
    AgentMessage m,
    bool Function() current,
  ) {
    if (!c.isOfficial ||
        !c.resolveOfficialProfiles ||
        m.outgoing ||
        m.senderIsBot) {
      return;
    }
    if (s.kind == 'group') {
      if (!s.nameIsManual && profileName(event['group_name']).isEmpty) {
        unawaited(_loadProfile(c, s, 'group', current));
      }
      if (m.senderNameIsFallback) {
        unawaited(_loadProfile(c, s, 'member', current, memberId: m.senderId));
      }
    } else if (c.useOiapiNickname && m.senderNameIsFallback) {
      unawaited(
        _loadProfile(
          c,
          s,
          'private',
          current,
          lookupId: text(event['_qq_lookup_id']),
        ),
      );
    }
  }

  Future<void> _loadProfile(
    AgentConnection c,
    AgentSession s,
    String kind,
    bool Function() current, {
    String memberId = '',
    String lookupId = '',
    bool force = false,
  }) {
    final key = _profileKey(c, kind, s.peerId, memberId),
        cached = store.get(_profileKey(c, kind, s.peerId, memberId)) ?? {};
    final pending = _profileJobs[key];
    if (pending != null) return pending;
    final at = DateTime.tryParse(text(cached['at']));
    final ttl = cached['ok'] == true
        ? (kind == 'group'
              ? const Duration(hours: 6)
              : const Duration(hours: 1))
        : const Duration(minutes: 5);
    if (!force && at != null && DateTime.now().difference(at) < ttl) {
      return Future.value();
    }
    final t = _transports[c.id];
    if (t == null || !current()) return Future.value();
    late final Future<void> job;
    job =
        (() async {
              final label = kind == 'group'
                  ? '群名'
                  : kind == 'member'
                  ? '群成员昵称'
                  : '单聊昵称';
              _log('info', '开始补全$label（与 AI 回复并行）', c.id, s.key, 'profile');
              try {
                final profile = await t.loadOfficialProfile(
                  kind,
                  s.peerId,
                  memberId: memberId,
                  lookupId: lookupId.isEmpty
                      ? text(cached['lookupId'])
                      : lookupId,
                  force: force,
                );
                if (!current()) return;
                final name = clipped(firstProfileName([profile['name']]), 128);
                if (name.isEmpty) {
                  throw const AgentException('平台未返回可用昵称 / 群名，保留原名称。');
                }
                await store.put(key, {
                  'name': name,
                  'at': DateTime.now().toIso8601String(),
                  'ok': true,
                  'source': profile['source'],
                  'lookupId': lookupId.isEmpty
                      ? text(cached['lookupId'])
                      : lookupId,
                });
                if (!current()) return;
                final fresh = session(s.key);
                if (fresh == null) return;
                if (kind != 'member' &&
                    !fresh.nameIsManual &&
                    (fresh.name == s.name ||
                        _fallbackSessionName(fresh) ||
                        fresh.name == text(cached['name']))) {
                  fresh.name = name;
                  await store.put('session:${s.key}', fresh.toJson());
                }
                if (kind != 'group' && current()) {
                  await store.enrichSender(
                    s.key,
                    kind == 'member' ? memberId : s.peerId,
                    name,
                  );
                }
                if (current()) {
                  _log('info', '$label已同步', c.id, s.key, 'profile');
                }
              } catch (e) {
                if (!current()) return;
                await store.put(key, {
                  ...cached,
                  'at': DateTime.now().toIso8601String(),
                  'ok': false,
                  'lookupId': lookupId.isEmpty
                      ? text(cached['lookupId'])
                      : lookupId,
                });
                if (current()) {
                  _log(
                    'warning',
                    '$label未补全：${describeError(e)}；不影响 AI 回复。',
                    c.id,
                    s.key,
                    'profile',
                  );
                }
              }
            })()
            .catchError((Object e) {
              if (current()) {
                _log('warning', '会话资料暂未能保存，不影响消息回复。', c.id, s.key, 'profile');
              }
            })
            .whenComplete(() {
              if (identical(_profileJobs[key], job)) _profileJobs.remove(key);
            });
    _profileJobs[key] = job;
    return job;
  }

  bool _fallbackSessionName(AgentSession s) =>
      isFallbackProfileName(s.name, s.peerId, isGroup: s.kind == 'group') ||
      s.name == '${s.kind == 'group' ? '群' : 'QQ'} ${s.peerId}';

  Future<void> _receive(
    AgentConnection c,
    Json event,
    bool Function() current,
  ) async {
    if (text(event['self_id']) != c.selfId) return;
    final type = text(event['post_type']);
    if (!{'message', 'message_sent'}.contains(type)) {
      if (type == 'notice' || type == 'request') {
        _log(
          'info',
          '收到 ${clipped(text(event['notice_type'] ?? event['request_type']), 80)} 事件',
          c.id,
        );
      }
      if (type == 'request' && !c.isOfficial && current()) {
        await _dispatchRequest(c, event);
      }
      return;
    }
    final kind = text(event['message_type']);
    if (!{'private', 'group'}.contains(kind)) return;
    final senderId = text(event['user_id']);
    final outgoing = senderId == c.selfId || type == 'message_sent';
    final peerId = text(
      kind == 'group'
          ? event['group_id']
          : outgoing
          ? (event['target_id'] ?? event['peer_id'])
          : event['user_id'],
    );
    if (!c.acceptsPeer(peerId)) return;
    final sender = object(event['sender']);
    final rawName = text(sender['card']).trim().isNotEmpty
        ? text(sender['card'])
        : text(sender['nickname']);
    final fallback =
        c.isOfficial &&
        (event['_sender_name_is_fallback'] == true ||
            isFallbackProfileName(rawName, senderId));
    final name = fallback
        ? firstProfileName([
            _cachedName(
              c,
              kind == 'group' ? 'member' : 'private',
              peerId,
              kind == 'group' ? senderId : '',
            ),
            rawName,
          ])
        : rawName;
    final groupName = c.isOfficial
        ? firstProfileName([
            event['group_name'],
            _cachedName(c, 'group', peerId),
          ])
        : text(event['group_name']);
    final s = await openSession(
      c.id,
      kind,
      peerId,
      name: kind == 'group' ? groupName : name,
      received: true,
    );
    final originalSessionName = s.name;
    if (!current()) return;
    final messageId = text(event['message_id']);
    if (messageId.isEmpty) return;
    final addressed = c.isOfficial && event['_mentioned'] == true;
    var message = AgentMessage(
      id: 'ob:$messageId',
      sessionKey: s.key,
      senderId: senderId,
      senderName: name.isEmpty ? senderId : name,
      segments: withLocalQuote(
        [
          if (c.isOfficial &&
              event['_mentioned'] == true &&
              !parseSegments(event['message']).any(
                (s) => s['type'] == 'at' && object(s['data'])['qq'] == c.selfId,
              ))
            {
              'type': 'at',
              'data': {'qq': c.selfId},
            },
          ...parseSegments(event['message'] ?? event['raw_message']),
        ],
        text(event['_quoted_index']),
        store.messages(s.key),
        sessionKey: s.key,
        currentId: 'ob:$messageId',
      ),
      outgoing: outgoing,
      addressed: addressed,
      senderNameIsFallback: fallback,
      senderIsBot: c.isOfficial && event['_sender_is_bot'] == true,
      source: c.protocol,
      referenceIndex: text(event['_reference_index']),
      time: DateTime.fromMillisecondsSinceEpoch(
        integer(event['time'], DateTime.now().millisecondsSinceEpoch ~/ 1000) *
            1000,
      ),
    );
    if (c.isOfficial && !s.nameIsManual) {
      final eventName = kind == 'group'
          ? profileName(event['group_name'])
          : fallback
          ? ''
          : name;
      if (eventName.isNotEmpty) {
        s.name = eventName;
      } else if (_fallbackSessionName(s) &&
          (kind == 'group' ? groupName : name).isNotEmpty) {
        s.name = kind == 'group' ? groupName : name;
      }
    }
    final previous = store
        .messages(s.key)
        .where((m) => m.id == message.id)
        .firstOrNull;
    final inserted = await store.append(message);
    var promoted = false;
    if (!inserted) {
      if (!c.isOfficial ||
          previous == null ||
          previous.outgoing ||
          previous.senderId != senderId) {
        return;
      }
      final oldAddressed =
          previous.addressed ||
          previous.segments.any(
            (seg) =>
                seg['type'] == 'at' && object(seg['data'])['qq'] == c.selfId,
          );
      promoted =
          addressed &&
          !oldAddressed &&
          !previous.autoHandled &&
          !_allowed(c, s, previous);
      bool hasBodyElements(AgentMessage m) => m.segments.any(
        (s) =>
            s['type'] == 'qq_body' &&
            (object(object(s['data'])['body'])['msg_elements'] as List? ?? [])
                .isNotEmpty,
      );
      final richSegments =
          hasBodyElements(message) && !hasBodyElements(previous)
          ? message.segments
          : previous.segments;
      message =
          (await store.updateMessage(
            s.key,
            message.id,
            (old) => old.copyWith(
              addressed: old.addressed || addressed,
              referenceIndex: old.referenceIndex.isEmpty
                  ? text(event['_reference_index'])
                  : old.referenceIndex,
              segments: !oldAddressed && addressed
                  ? [
                      {
                        'type': 'at',
                        'data': {'qq': c.selfId},
                      },
                      ...richSegments,
                    ]
                  : richSegments,
              senderName: !fallback ? name : old.senderName,
              senderNameIsFallback: !fallback
                  ? false
                  : old.senderNameIsFallback,
            ),
          )) ??
          previous;
      if (promoted) {
        _log(
          'info',
          '同 ID 全量 / @ 事件已合并，补充机器人唤醒；聊天记录不重复新增。',
          c.id,
          s.key,
          'receive',
        );
      }
    }
    if (!current()) return;
    // Merge into the CURRENT session so a profile response or manual edit that
    // arrived during append is never overwritten by the older event snapshot.
    final fresh = session(s.key) ?? s;
    if (!fresh.nameIsManual &&
        (fresh.name == originalSessionName || _fallbackSessionName(fresh))) {
      fresh.name = s.name;
    }
    if (inserted) {
      fresh.updated = DateTime.now();
      if (!outgoing) fresh.unread++;
    }
    await store.put('session:${s.key}', fresh.toJson());
    _changed();
    _scheduleProfiles(c, fresh, event, message, current);
    if (inserted) {
      _log(
        'info',
        '收到 [${c.protocolLabel}/${text(event['_qq_event_type']).isEmpty ? kind : text(event['_qq_event_type'])}] 消息 ${clipped(messageId, 64)} · 文本 ${message.plain.length} 字符 / ${message.segments.where((s) => s['type'] != 'text' && s['type'] != 'at').length} 个附件段',
        c.id,
        fresh.key,
        'receive',
      );
    }
    if (current() && !outgoing && (inserted || promoted)) {
      final blocked = _triggerBlock(
        c,
        fresh,
        message,
        ignoreWake: _burstWindows[fresh.key]?.senderId == message.senderId,
      );
      if (blocked != null) {
        _ignored(c, fresh, message, blocked);
      } else if ((await _offerBurst(c, fresh, message) ||
              _enqueue(c, fresh, message)) &&
          c.isOfficial) {
        await store.updateMessage(
          s.key,
          message.id,
          (old) => old.copyWith(autoHandled: true),
        );
      }
    }
  }

  bool _allowed(AgentConnection c, AgentSession s, AgentMessage m) =>
      _triggerBlock(c, s, m) == null;
  String? _triggerBlock(
    AgentConnection c,
    AgentSession s,
    AgentMessage m, {
    bool ignoreWake = false,
  }) {
    if (s.paused) return '当前会话已暂停自动回复';
    if (m.senderId == c.selfId || m.senderIsBot) return '机器人消息不触发 AI，避免循环对话';
    if (c.userAllowlist.isNotEmpty && !c.userAllowlist.contains(m.senderId)) {
      return '发送者不在允许名单中';
    }
    if (s.kind == 'group' &&
        c.groupAllowlist.isNotEmpty &&
        !c.groupAllowlist.contains(s.peerId)) {
      return '群聊不在允许名单中';
    }
    if (s.kind == 'private') return c.privateReply ? null : '此连接已关闭私聊自动处理';
    if (ignoreWake && c.groupTrigger != 'off') return null;
    final command = _commandText(c, m);
    final extraWake = c.extraWakePrefixes.any(
      (p) => matchesAgentWakePrefix(command, p),
    );
    final accepted = switch (c.groupTrigger) {
      'off' => false,
      'all' => true,
      'command' =>
        extraWake ||
            _matchesPrefix(command, c.commandPrefix) ||
            _pluginMatches(c, command),
      _ =>
        extraWake ||
            (c.isOfficial && m.addressed) ||
            m.segments.any(
              (seg) =>
                  seg['type'] == 'at' &&
                  text(object(seg['data'])['qq']) == c.selfId,
            ),
    };
    return accepted
        ? null
        : c.groupTrigger == 'off'
        ? '此连接已关闭群聊自动处理'
        : c.groupTrigger == 'command'
        ? '未匹配 AI 命令或额外唤醒前缀'
        : '未检测到 @ 当前机器人或额外唤醒前缀';
  }

  String _commandText(AgentConnection c, AgentMessage message) => message
      .segments
      .map(
        (s) => s['type'] == 'text'
            ? text(object(s['data'])['text'])
            : s['type'] == 'qq_body'
            ? text(
                object(s['data'])['commandText'] ??
                    object(object(s['data'])['body'])['content'],
              )
            : '',
      )
      .join()
      .trim();
  bool _pluginMatches(AgentConnection c, String value) => extensions.any(
    (e) =>
        e.enabled &&
        e.kind == 'plugin' &&
        c.pluginIds.contains(e.id) &&
        e.commands.any((cmd) => _matchesPrefix(value, text(cmd['prefix']))),
  );
  bool _matchesPrefix(String content, String prefix) =>
      content == prefix ||
      content.startsWith('$prefix ') ||
      content.startsWith('$prefix\n');

  bool _enqueue(
    AgentConnection c,
    AgentSession s,
    AgentMessage message, {
    bool forced = false,
    List<AgentMessage> batch = const [],
  }) {
    final command = _commandText(c, message);
    final hasPlugin = _pluginMatches(c, command);
    if (!forced && !c.aiEnabled && !hasPlugin) {
      _ignored(c, s, message, '自动 AI 回复未开启，请在机器人连接中开启');
      return false;
    }
    final now = DateTime.now(), previous = _lastTrigger[s.key];
    if (!forced &&
        previous != null &&
        now.difference(previous).inSeconds < c.cooldownSeconds) {
      _ignored(c, s, message, '当前会话在 ${c.cooldownSeconds} 秒触发冷却中');
      return false;
    }
    if (_queued >= 20) {
      _log('warning', 'AI 待处理消息过多，本条未触发回复', c.id);
      return false;
    }
    _lastTrigger[s.key] = now;
    final accountEpoch = _epochs[c.id] ?? 0,
        sessionEpoch = _sessionEpochs[s.key] ?? 0;
    final transport = _transports[c.id];
    bool current() =>
        !_closed &&
        (_epochs[c.id] ?? 0) == accountEpoch &&
        (_sessionEpochs[s.key] ?? 0) == sessionEpoch &&
        transport != null &&
        identical(_transports[c.id], transport) &&
        transport.connected;
    _queued++;
    _replyState(c, s, 'queued', '已触发，等待生成回复。', messageId: message.id);
    final before = _queues[s.key] ?? Future<void>.value();
    final task = before
        .then((_) async {
          if (!current()) return;
          await _acquire();
          final turn = AgentTurn(current);
          try {
            if (!current()) return;
            _turns[s.key] = turn;
            _batchContexts[s.key] = batch.isEmpty ? [message] : batch;
            _changed();
            await _respond(c, s, message, turn, forced: forced);
          } catch (e) {
            if (current() && !turn.cancel.isCancelled) {
              _replyState(
                c,
                s,
                'error',
                '回复未完成：${describeError(e)}',
                error: true,
                messageId: message.id,
              );
            }
          } finally {
            if (identical(_turns[s.key], turn)) _turns.remove(s.key);
            _batchContexts.remove(s.key);
            _release();
            _changed();
          }
        })
        .whenComplete(() {
          _queued--;
        });
    _queues[s.key] = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_queues[s.key], task)) _queues.remove(s.key);
      }),
    );
    return true;
  }

  Future<void> _acquire() async {
    if (_activeAi < 2) {
      _activeAi++;
      return;
    }
    final c = Completer<void>();
    _permits.add(c);
    await c.future;
  }

  void _release() {
    if (_permits.isNotEmpty) {
      _permits.removeAt(0).complete();
    } else {
      _activeAi--;
    }
  }

  Future<void> _respond(
    AgentConnection c,
    AgentSession s,
    AgentMessage trigger,
    AgentTurn turn, {
    required bool forced,
  }) async {
    var command = _commandText(c, trigger);
    if (!forced) {
      for (final e in extensions.where(
        (e) => e.enabled && e.kind == 'plugin' && c.pluginIds.contains(e.id),
      )) {
        for (final cmd in e.commands) {
          final prefix = text(cmd['prefix']);
          if (!_matchesPrefix(command, prefix)) continue;
          final stateKey = 'extension-state:${e.id}:${s.key}';
          final result = await extensionRunner.execute(
            e,
            object(cmd['handler']),
            {
              'args': {'text': command.substring(prefix.length).trim()},
              'sender': {'id': trigger.senderId, 'name': trigger.senderName},
              'session': {'kind': s.kind, 'peerId': s.peerId, 'name': s.name},
              'state': store.get(stateKey) ?? <String, dynamic>{},
            },
            cancel: turn.cancel,
            active: () => turn.active,
          );
          turn.check();
          final answer = text(result['text'] ?? result['reply']);
          if (answer.isNotEmpty) {
            await send(
              s.key,
              clipped(answer, 12000),
              source: 'plugin',
              replyMessageId: trigger.id,
              turn: turn,
            );
          }
          turn.check();
          if (result['state'] is Map) {
            await store.put(stateKey, object(result['state']));
          }
          _log('info', '命令插件已完成：${e.name}', c.id);
          return;
        }
      }
    }
    if (!forced && !c.aiEnabled) return;
    final fresh = session(s.key) ?? s;
    final presetId = fresh.presetId.isEmpty ? c.presetId : fresh.presetId;
    final preset = presets.where((p) => p.id == presetId).firstOrNull;
    final provider = providers
        .where((p) => p.id == preset?.providerId)
        .firstOrNull;
    if (preset == null || provider == null) {
      throw const AgentException('请先为当前 AI 预设选择模型配置。');
    }
    if ((_transports[c.id]?.replyCapacity(s.kind, s.peerId, trigger.id) ?? 1) <=
        0) {
      throw const AgentException('QQBot 原消息的被动回复窗口已过期或次数已用完，请让用户发送新消息；未调用模型。');
    }
    final all = store.messages(s.key);
    final index = all.indexWhere((m) => m.id == trigger.id);
    final afterId = text(store.get('context:${s.key}')?['afterId']);
    final barrier = all.indexWhere((m) => m.id == afterId);
    final history = (index < 0 ? all : all.take(index + 1))
        .skip(barrier + 1)
        .toList();
    if (history.isEmpty) history.add(trigger);
    final rules = <String>[];
    final ownerIds = <String>{};
    var resolvedPreset = preset;
    for (final extension in _runtimeExtensions(c, preset)) {
      final hook = await _runPackage(
        c,
        extension,
        'plugin',
        s: s,
        trigger: trigger,
        turn: turn,
        extra: {
          'kind': s.kind,
          'selfId': s.selfId,
          'triggerEntries': [
            {
              'senderId': trigger.senderId,
              'atMe': trigger.segments.any(
                (seg) =>
                    seg['type'] == 'at' &&
                    text(object(seg['data'])['qq']) == c.selfId,
              ),
              'atAll': trigger.segments.any(
                (seg) =>
                    seg['type'] == 'at' && object(seg['data'])['qq'] == 'all',
              ),
            },
          ],
          'trustedSenders': history
              .where((m) => !m.outgoing)
              .map((m) => m.senderId)
              .toSet()
              .toList(),
          'persona': {'roleText': resolvedPreset.prompt, 'customRules': ''},
        },
      );
      turn.check();
      ownerIds.addAll(strings(hook['owners']));
      final persona = object(hook['persona']);
      if (text(persona['roleText']).isNotEmpty) {
        resolvedPreset = AgentPreset.fromJson({
          ...resolvedPreset.toJson(),
          'prompt': text(persona['roleText']),
        });
      }
      if (text(persona['customRules']).isNotEmpty) {
        rules.add(text(persona['customRules']));
      }
      if (text(hook['rules']).isNotEmpty) {
        rules.add(text(hook['rules']));
      } else {
        final sections =
            (hook['sections'] as List? ??
                    object(extension.packageManifest['prompt'])['sections']
                        as List? ??
                    [])
                .map(object)
                .toList()
              ..sort(
                (a, b) => integer(
                  b['priority'],
                  0,
                ).compareTo(integer(a['priority'], 0)),
              );
        rules.addAll(
          sections.map((j) => text(j['content'])).where((v) => v.isNotEmpty),
        );
      }
    }
    final imageDescriptionProvider = providers
        .where((p) => p.id == resolvedPreset.imageDescriptionProviderId)
        .firstOrNull;
    if (resolvedPreset.imageDescriptionProviderId.isNotEmpty &&
        (imageDescriptionProvider == null ||
            !imageDescriptionProvider.vision)) {
      throw const AgentException('图片转述模型不存在或未开启图片输入，请检查预设。');
    }
    var reasoning = '';
    _replyState(
      c,
      s,
      'preparing',
      '准备 AI 上下文：${history.length} 条消息 · 预设 ${resolvedPreset.name}',
      messageId: trigger.id,
    );
    var inputHistory = !c.isOfficial && resolvedPreset.readMessageContext
        ? await _readOneBotRecords(
            c,
            s,
            history,
            resolvedPreset.historyMessages,
            turn,
          )
        : history;
    final batch = _batchContexts[s.key] ?? [trigger];
    if (batch.length > 1) {
      final ids = batch.map((m) => m.id).toSet();
      inputHistory = [
        ...inputHistory.where((m) => !ids.contains(m.id)),
        trigger.copyWith(
          segments: [
            {
              'type': 'text',
              'data': {
                'text': clipped(
                  batch.map((m) => m.inputText).join('\n'),
                  12000,
                ),
              },
            },
            ...batch.expand(
              (m) => m.segments.where(
                (seg) => seg['type'] != 'text' && seg['type'] != 'at',
              ),
            ),
          ],
        ),
      ];
    }
    turn.check();
    final runtime = _runtimeExtensions(c, resolvedPreset);
    var toolOutputs = 0;
    await _runHooks(c, runtime, 'before-context', {}, fresh, trigger, turn);
    final answer = await ai.reply(
      provider: provider,
      preset: resolvedPreset,
      session: fresh,
      history: inputHistory,
      skills: extensions,
      systemRules: clipped(
        [
          ...rules,
          if (c.isOfficial)
            '本轮 QQBot 当前最多剩余 ${_transports[c.id]?.replyCapacity(s.kind, s.peerId, trigger.id) ?? 0} 次被动回复。工具发送图片 / 文本也会消耗额度；优先保留最终答复，勿无意义连发。',
        ].join('\n\n'),
        16000,
      ),
      ownerIds: ownerIds,
      pluginIds: c.pluginIds.toSet(),
      lifecycle: runtime.isEmpty
          ? null
          : (phase, data) => _runHooks(
              c,
              runtime,
              phase,
              data,
              fresh,
              trigger,
              turn,
              onSent: () => toolOutputs++,
            ),
      requestParameters: runtime.isEmpty
          ? null
          : (body) => _pluginRequestParameters(
              c,
              runtime,
              body,
              fresh,
              trigger,
              turn,
            ),
      onUsageDetail: (used, usage) =>
          _recordRunUsage(c, fresh, trigger, turn, used, usage),
      onJavaScriptTool: (extension, handler, input) async {
        final result = await _runPackage(
          c,
          extension,
          'tool',
          args: {'id': handler['id'], 'args': object(input['args'])},
          s: fresh,
          trigger: trigger,
          turn: turn,
          onSent: () => toolOutputs++,
        );
        return {
          'text': text(
            result['content'] ?? result['text'] ?? jsonEncode(result),
          ),
          if (result['isError'] == true) 'isError': true,
        };
      },
      allowFinish: runtime.any(
        (e) =>
            strings(
              object(e.manifest['compatibility'])['hooks'],
            ).contains('after-response') ||
            strings(
              object(e.manifest['compatibility'])['requirements'],
            ).contains('media'),
      ),
      deferAfterResponse: true,
      hasToolOutput: () => toolOutputs > 0,
      imageDescriptionProvider: imageDescriptionProvider,
      onReasoning: (value) => reasoning = value,
      onProgress: (phase, message) {
        if (turn.active) {
          _replyState(c, s, phase, message, messageId: trigger.id);
        }
      },
      onNotice: (message) =>
          _log('warning', describeError(AgentException(message)), c.id),
      sendImage: (bytes, name) async {
        final r = await sendImage(
          s.key,
          bytes,
          name: name,
          turn: turn,
          replyMessageId: trigger.id,
        );
        toolOutputs++;
        return r;
      },
      sendText: (message) async {
        await send(
          s.key,
          message,
          source: 'skill',
          turn: turn,
          replyMessageId: trigger.id,
        );
        toolOutputs++;
        return {'ok': true};
      },
      sendMedia: (bytes, name, type) async {
        final r = await sendAudio(
          s.key,
          bytes,
          turn: turn,
          replyMessageId: trigger.id,
        );
        toolOutputs++;
        return r;
      },
      turn: turn,
      onUsage: (input, output) {
        unawaited(
          store.addUsage(input, output).catchError((Object _) {
            _log('warning', '本地模型用量未能保存', c.id);
          }),
        );
      },
      onTool: (name) =>
          _replyState(c, s, 'tool', '工具调用：$name', messageId: trigger.id),
    );
    turn.check();
    Future<void> afterResponse() async {
      try {
        await _runHooks(
          c,
          runtime,
          'after-response',
          {
            'response': {
              'message': {'role': 'assistant', 'content': answer},
            },
          },
          fresh,
          trigger,
          turn,
          onSent: () => toolOutputs++,
        );
      } catch (error) {
        if (turn.active) {
          _log(
            'warning',
            '消息已发送，插件后续处理未完成：${describeError(error)}',
            c.id,
            s.key,
            'plugin',
          );
        }
      }
    }

    if (answer.isEmpty && toolOutputs > 0) {
      await afterResponse();
      _replyState(
        c,
        s,
        'done',
        '已通过工具发送 $toolOutputs 条消息，不重复发送正文。',
        messageId: trigger.id,
      );
      return;
    }
    final capacity = _transports[c.id]?.replyCapacity(
      s.kind,
      s.peerId,
      trigger.id,
    );
    if (capacity != null && capacity <= 0) {
      throw const AgentException('QQBot 回复额度已用完（可能已发送工具图片 / 文本），本轮正文未继续发送。');
    }
    final planned = resolvedPreset.multiMessageReply
        ? resolvedPreset.maxReplyMessages
        : 1;
    final maxParts = capacity == null || planned <= capacity
        ? planned
        : capacity;
    final parts = agentReplyMessages(
      answer,
      enabled: resolvedPreset.multiMessageReply,
      maxParts: maxParts,
    );
    var sent = 0;
    try {
      for (var i = 0; i < parts.length; i++) {
        turn.check();
        if (i > 0 && resolvedPreset.replyIntervalMs > 0) {
          await Future<void>.delayed(
            Duration(milliseconds: resolvedPreset.replyIntervalMs),
          );
          turn.check();
        }
        final slots = _transports[c.id]?.replyCapacity(
          s.kind,
          s.peerId,
          trigger.id,
        );
        if (slots != null && slots > 0 && parts.length - i > slots) {
          final tail = i + slots - 1;
          parts[tail] = parts.skip(tail).join('\n\n');
          parts.removeRange(tail + 1, parts.length);
          _log(
            'info',
            'QQBot 剩余回复额度发生变化，后续内容已合并，未额外请求模型。',
            c.id,
            s.key,
            'sending',
          );
        }
        _replyState(
          c,
          s,
          'sending',
          '正在发送第 ${i + 1}/${parts.length} 条回复（已确认 $sent 条）',
          messageId: trigger.id,
        );
        await send(
          s.key,
          parts[i],
          source: 'ai',
          reasoning: i == 0 && resolvedPreset.showReasoning ? reasoning : '',
          turn: turn,
          replyMessageId: trigger.id,
        );
        sent++;
      }
    } catch (e) {
      if (sent > 0 && turn.active) {
        throw AgentException(
          '已确认发送 $sent/${parts.length} 条，后续发送停止：${describeError(e)}',
        );
      }
      rethrow;
    }
    await afterResponse();
    _replyState(
      c,
      s,
      'done',
      '回复完成，已确认发送 $sent 条消息${resolvedPreset.multiMessageReply ? '；分条未额外调用模型' : ''}。',
      messageId: trigger.id,
    );
  }

  Future<void> regenerate(String key) async {
    final s = session(key);
    if (s == null) throw const AgentException('会话不存在。');
    final c = connection(s.connectionId)!;
    final message = store.messages(key).where((m) => !m.outgoing).lastOrNull;
    if (message == null) throw const AgentException('此会话还没有收到消息。');
    if (!connected(c.id)) throw const AgentException('请先启动此机器人连接。');
    stopReply(key);
    _enqueue(c, s, message, forced: true);
  }

  Future<void> send(
    String sessionKey,
    String content, {
    String source = 'manual',
    String reasoning = '',
    List<Json>? segments,
    AgentTurn? turn,
    String? replyMessageId,
  }) async {
    final s = session(sessionKey);
    if (s == null) throw const AgentException('会话不存在。');
    _validateSession(s);
    final t = _transports[s.connectionId];
    if (t?.connected != true) throw const AgentException('请先连接此机器人账号。');
    if (segments == null &&
        (content.trim().isEmpty || content.length > 12000)) {
      throw const AgentException('消息不能为空且不能超过 12000 字符。');
    }
    final message = segments ?? [textSegment(content)];
    if (message.length > 100 || jsonEncode(message).length > 8 * 1024 * 1024) {
      throw const AgentException('消息或附件过大。');
    }
    // Never let model-produced CQ text become executable CQ segments.
    turn?.check();
    _log(
      'info',
      '准备发送 [$source] · ${s.kind == 'group' ? '群聊' : '单聊'} · ${message.length} 个消息段',
      s.connectionId,
      s.key,
      'send',
    );
    Json response;
    try {
      response = object(
        await t!
            .call(s.kind == 'group' ? 'send_group_msg' : 'send_private_msg', {
              s.kind == 'group' ? 'group_id' : 'user_id': s.protocol == 'qqbot'
                  ? s.peerId
                  : int.parse(s.peerId),
              if (s.protocol == 'qqbot' && replyMessageId != null)
                '_reply_id': replyMessageId.replaceFirst('ob:', ''),
              'message': message,
              'auto_escape': true,
            }),
      );
    } catch (e) {
      _log(
        'error',
        '协议发送未确认成功：${describeError(e)}',
        s.connectionId,
        s.key,
        'send',
      );
      rethrow;
    }
    final id = text(response['message_id']);
    if (id.isEmpty) throw const AgentException('协议端未返回消息 ID；请先核对是否已发出。');
    await store.append(
      AgentMessage(
        id: 'ob:$id',
        sessionKey: s.key,
        senderId: s.selfId,
        senderName: nickname(s.connectionId).isEmpty
            ? '我'
            : nickname(s.connectionId),
        segments: message,
        outgoing: true,
        source: source,
        reasoning: source == 'ai' ? clipped(reasoning, 16000) : '',
      ),
    );
    final fresh = session(s.key) ?? s;
    fresh.updated = DateTime.now();
    await store.put('session:${s.key}', fresh.toJson());
    _log(
      'info',
      '消息发送成功，已取得平台回执 ${clipped(id, 80)}',
      s.connectionId,
      s.key,
      'send',
    );
  }

  Future<Json> sendImage(
    String sessionKey,
    Uint8List bytes, {
    String name = 'image.png',
    AgentTurn? turn,
    String? replyMessageId,
  }) async {
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
      throw const AgentException('图片需要在 5 MB 以内。');
    }
    final png =
        bytes.length > 8 &&
        bytes.take(8).toList().join(',') == '137,80,78,71,13,10,26,10';
    final jpg = bytes.length > 3 && bytes[0] == 255 && bytes[1] == 216;
    final gif =
        bytes.length > 6 &&
        ascii.decode(bytes.take(3).toList(), allowInvalid: true) == 'GIF';
    final webp =
        bytes.length > 12 &&
        ascii.decode(bytes.take(4).toList(), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP';
    if (!png && !jpg && !gif && !webp) {
      throw const AgentException('请发送 PNG、JPEG、GIF 或 WebP 图片。');
    }
    await send(
      sessionKey,
      '',
      source: 'skill',
      turn: turn,
      replyMessageId: replyMessageId,
      segments: [
        {
          'type': 'image',
          'data': {
            'file': 'base64://${base64Encode(bytes)}',
            'name': clipped(name, 100),
          },
        },
      ],
    );
    return {'ok': true, 'message_id': store.messages(sessionKey).last.id};
  }

  Future<Json> sendAudio(
    String sessionKey,
    Uint8List bytes, {
    AgentTurn? turn,
    String? replyMessageId,
  }) async {
    final audio = AgentAudio(bytes);
    await send(
      sessionKey,
      '',
      source: 'skill',
      turn: turn,
      replyMessageId: replyMessageId,
      segments: [audio.segment],
    );
    return {
      'ok': true,
      'message_id': store.messages(sessionKey).last.id,
      'type': 'record',
      'name': audio.name,
    };
  }

  Future<dynamic> readForward(String connectionId, String messageId) async {
    if (messageId.isEmpty || messageId.length > 256) {
      throw const AgentException('聊天记录 ID 无效。');
    }
    final t = _transports[connectionId];
    if (t?.connected != true) throw const AgentException('请先连接 OneBot。');
    final result = object(await t!.call('get_forward_msg', {'id': messageId}));
    // OneBot 11 specifies `message`; some implementations return `messages`.
    return {
      ...result,
      'messages': result['messages'] ?? result['message'] ?? [],
    };
  }

  Future<List<AgentMessage>> _readOneBotRecords(
    AgentConnection c,
    AgentSession s,
    List<AgentMessage> history,
    int historyMessages,
    AgentTurn turn,
  ) async {
    final cache = <String, Json>{};
    final result = <AgentMessage>[];
    // Read newest first so the current user's record takes priority.
    for (final message in history.reversed.take(historyMessages + 1)) {
      turn.check();
      final segments = <Json>[...message.segments];
      if (!message.outgoing) {
        for (final segment in message.segments.where(
          (s) => s['type'] == 'forward',
        )) {
          final id = text(object(segment['data'])['id']);
          if (id.isEmpty || id.length > 512) continue;
          Json body;
          if (cache.containsKey(id)) {
            body = cache[id]!;
          } else if (cache.length >= 3) {
            body = {'context': '〔本轮最多读取 3 份聊天记录，其余记录未读取。〕'};
          } else {
            _replyState(
              c,
              s,
              'context',
              '正在读取用户提供的聊天记录…',
              messageId: message.id,
            );
            try {
              final response = await readForward(
                c.id,
                id,
              ).timeout(const Duration(seconds: 6));
              turn.check();
              body = oneBotRecordData(response);
              if (text(body['context']).isEmpty) {
                body['context'] = '〔协议端未返回聊天记录原文，不可猜测内容。〕';
              }
            } catch (e) {
              turn.check();
              _log(
                'warning',
                '聊天记录原文未能读取：${describeError(e)}',
                c.id,
                s.key,
                'context',
              );
              body = {'context': '〔聊天记录原文读取失败，不可假装已阅读；可请用户重新转发或提供文字。〕'};
            }
            cache[id] = body;
          }
          segments.add({'type': 'qq_body', 'data': body});
        }
      }
      result.add(message.copyWith(segments: segments));
    }
    return result.reversed.toList();
  }

  Future<List<String>> listModels(AgentProvider p) async {
    p.validate(requireModel: false);
    final cancel = CancelToken();
    _cancelTests.add(cancel);
    try {
      final result = object(
        await http.request(
          p.endpoint('models'),
          cancel: cancel,
          headers: {
            if (p.apiKey.isNotEmpty) 'Authorization': 'Bearer ${p.apiKey}',
          },
          timeoutSeconds: 20,
        ),
      );
      return (result['data'] as List? ?? [])
          .map((v) => text(object(v)['id']))
          .where((s) => s.isNotEmpty)
          .take(500)
          .toList();
    } finally {
      _cancelTests.remove(cancel);
    }
  }

  Future<String> testModel(AgentProvider p) async {
    p.validate();
    final cancel = CancelToken();
    _cancelTests.add(cancel);
    try {
      final result = await ai.model.complete(p, {
        'model': p.model,
        'stream': false,
        'max_tokens': 64,
        'messages': [
          {'role': 'user', 'content': '请只回复：连接成功'},
        ],
      }, cancel);
      final choices = result['choices'];
      if (choices is! List || choices.isEmpty) {
        throw const AgentException('模型未返回有效回复。');
      }
      final content = text(object(object(choices.first)['message'])['content']);
      if (content.trim().isEmpty) {
        throw const AgentException('接口已响应，但模型返回空内容，请检查模型参数。');
      }
      return clipped(content, 300);
    } finally {
      _cancelTests.remove(cancel);
    }
  }

  Json snapshot() => {
    'ready': ready,
    'revision': revision,
    'connections': [
      for (final c in connections)
        {
          ...c.toJson(secrets: false),
          'status': status(c.id),
          'connected': connected(c.id),
          'started': started(c.id),
          'nickname': nickname(c.id),
        },
    ],
    'providers': providers.map((p) => p.toJson(secrets: false)).toList(),
    'presets': presets.map((p) => p.toJson()).toList(),
    'extensions': extensions
        .map((e) => e.toJson(includeSecrets: false, includeFiles: false))
        .toList(),
    'sessions': sessions().map((s) => s.toJson()).toList(),
    'usage': usage,
    'busy': busySessions.toList(),
    'replyStates': _replyStates,
    'logs': logs,
  };
  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    _notification?.cancel();
    _notification = null;
    _cancelAll();
    for (final cancel in _cancelTests) {
      cancel.cancel();
    }
    for (final t in _transports.values.toList()) {
      t.onEvent = null;
      t.onState = null;
      await t.stop();
    }
    _transports.clear();
    http.close();
    scripts.close();
    await Future.wait(_queues.values.toList());
    await Future.wait(_ingest.values.toList());
    await Future.wait(_profileJobs.values.toList());
    await packages.drain();
    try {
      await _opening;
    } catch (_) {}
    await store.close();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}
