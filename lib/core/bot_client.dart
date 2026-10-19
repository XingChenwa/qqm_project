import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../models/message.dart';
import '../models/config.dart';
import '../models/outgoing_message.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../services/storage_service.dart';
import '../services/profile_request_queue.dart';
import '../services/oiapi_service.dart';
import '../utils/profile_helpers.dart';
import '../utils/helpers.dart';

enum ConnectStep { idle, gettingToken, gettingGateway, connecting, done }

class BotClient extends ChangeNotifier {
  final Logger _log = Logger('BotClient');
  final StorageService _storage;
  final ApiService _apiService;
  final WebSocketService _wsService;
  ProfileRequestQueue _profileRequests;
  ProfileRequestQueue _nicknameRequests;
  final OiapiService _oiapiService;
  int _nicknameGeneration = 0;
  final _profileSyncs = <String, Future<void>>{};
  final _memberProfiles = <String, Map<String, String>>{};
  final _memberCheckedAt = <String, DateTime>{};
  int _profileGeneration = 0;
  String _botAvatarUrl = '';
  Future<void>? _botProfileSync;

  BotConfig _config = BotConfig();
  final List<MessageModel> _messages = [];
  final List<ChatSession> _sessions = [];
  final Map<String, String> _lastInboundMessageIds = {};
  final Map<String, int> _replySequences = {};
  final Map<String, ({String id, DateTime at, String type})> _replyEvents = {};
  final Set<String> _acknowledgedInteractions = {};
  final Set<String> _dispatchedInteractions = {};
  final Set<String> _autoDispatchedMessageIds = {};
  final Map<String, Future<void>> _pendingPluginDispatches = {};
  int _fullGroupMessageCount = 0;
  Future<String?>? _tokenRequest;
  int _configRevision = 0;
  int _accountEpoch = 0;
  Future<void> _configWrites = Future<void>.value();
  int get accountEpoch => _accountEpoch;
  List<BotConfig> get botProfiles => _storage.getBotProfiles();

  Future<void> switchBot(String appId) async {
    final selected = botProfiles.where((bot) => bot.appId == appId).firstOrNull;
    if (selected == null) throw StateError('机器人配置不存在');
    if (selected.appId == _config.appId) return;
    final reconnect = isConnected || isConnecting;
    await updateConfig(selected);
    if (reconnect && !_disposed && _config.appId == appId) await connect();
  }

  Timer? _tokenRefreshTimer;
  String _lastSendError = '';
  bool _disposed = false;
  int _connectionAttempt = 0;
  String _connectionStatus = '未连接';
  String _connectionError = '';
  ConnectStep _connectStep = ConnectStep.idle;
  bool _isConnecting = false;
  String _botId = '';
  String _botName = '';
  String _gatewaySessionId = '';
  String _lastEventType = '';
  DateTime? _lastEventAt;
  DateTime? _lastHeartbeatAckAt;
  int _heartbeatIntervalMs = 0;

  Function(MessageModel)? onMessageReceived;
  Function(String log)? onLog;

  BotClient(
    this._storage, {
    ApiService? apiService,
    WebSocketService? webSocketService,
    ProfileRequestQueue? profileRequests,
    ProfileRequestQueue? nicknameRequests,
    OiapiService? oiapiService,
  }) : _apiService = apiService ?? ApiService(),
       _profileRequests = profileRequests ?? ProfileRequestQueue(),
       _nicknameRequests = nicknameRequests ?? ProfileRequestQueue(),
       _oiapiService = oiapiService ?? OiapiService(),
       _wsService = webSocketService ?? WebSocketService() {
    _loadConfig();
    _wsService.refreshAccessToken = _getAccessToken;
    _wsService.onConnectionStateChanged = (status) {
      if (_disposed) return;
      if (status != null) {
        _connectionStatus = status;
        if (_wsService.isConnected) _scheduleTokenRefresh();
        notifyListeners();
        _addLog('连接状态: $status');
      }
    };
    _wsService.onReady = _handleReady;
    _wsService.onDispatch = _handleDispatchEvent;
    _wsService.onHello = (interval) {
      _heartbeatIntervalMs = interval;
      _addLog('收到 Hello，心跳间隔 ${interval}ms');
      notifyListeners();
    };
    _wsService.onHeartbeatAck = () {
      if (_disposed) return;
      _lastHeartbeatAckAt = DateTime.now();
      notifyListeners();
    };
    _wsService.messageStream.listen(_handleIncomingMessage);
  }

  BotConfig get config => _config;
  String get connectionStatus => _connectionStatus;
  String get connectionError => _connectionError;
  String get lastSendError => _lastSendError;
  ConnectStep get connectStep => _connectStep;
  bool get isConnected => _wsService.isConnected;
  bool get isConnecting => _isConnecting;
  List<MessageModel> get messages =>
      List.unmodifiable(_messages.map(_withUserAvatar));
  List<ChatSession> get sessions => _sessions;
  String get botId => _botId;
  String get botName => _botName;
  String get botAvatarUrl => _botAvatarUrl;
  String get gatewaySessionId => _gatewaySessionId;
  String get lastEventType => _lastEventType;
  DateTime? get lastEventAt => _lastEventAt;
  DateTime? get lastHeartbeatAckAt => _lastHeartbeatAckAt;
  int get heartbeatIntervalMs => _heartbeatIntervalMs;
  int get fullGroupMessageCount => _fullGroupMessageCount;
  bool shouldAutoRespondTo(MessageModel message) =>
      _ownsMessage(message) && !message.isBotAuthor && !message.isRecalled;
  bool _ownsMessage(MessageModel message) =>
      message.extra?['botAppId'] == null ||
      message.extra?['botAppId'] == _config.appId;
  String get botDisplayName => _botName.isNotEmpty ? _botName : '未获取机器人资料';

  /// Get a valid access token, refreshing if expired.
  Future<String?> _getAccessToken() {
    if (!_config.isTokenExpired) return Future.value(_config.accessToken);
    if (_tokenRequest != null) return _tokenRequest!;
    late final Future<String?> pending;
    pending = _refreshAccessToken().whenComplete(() {
      if (identical(_tokenRequest, pending)) _tokenRequest = null;
    });
    _tokenRequest = pending;
    return pending;
  }

  Future<String?> _refreshAccessToken() async {
    if (_config.appId.isEmpty || _config.clientSecret.isEmpty) {
      _connectionError = '请先在设置中填写 AppID 和 ClientSecret';
      _addLog(_connectionError);
      return null;
    }

    if (_isConnecting) {
      _connectStep = ConnectStep.gettingToken;
      notifyListeners();
    }
    _addLog('正在获取 access_token...');

    final requestedConfig = _config;
    final requestedRevision = _configRevision;
    final result = await _apiService.getAccessToken(
      appId: requestedConfig.appId,
      clientSecret: requestedConfig.clientSecret,
    );
    if (_disposed ||
        requestedRevision != _configRevision ||
        !identical(requestedConfig, _config)) {
      return null;
    }

    final data = result.data;
    if (!result.isSuccess || data == null) {
      _connectionError = '获取访问凭证失败: ${result.error ?? '返回数据为空'}';
      _addLog(_connectionError);
      return null;
    }

    _config.accessToken = data.accessToken;
    _config.tokenExpiresAt =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 + data.expiresIn;
    await _storage.saveBotConfig(_config);
    if (_disposed || requestedRevision != _configRevision) return null;
    _wsService.updateAccessToken(data.accessToken);
    _scheduleTokenRefresh();
    _addLog('access_token 获取成功 (有效期 ${data.expiresIn}秒)');
    return _config.accessToken;
  }

  void _scheduleTokenRefresh() {
    _tokenRefreshTimer?.cancel();
    if (_disposed || !isConnected) return;
    final seconds =
        (_config.tokenExpiresAt -
                DateTime.now().millisecondsSinceEpoch ~/ 1000 -
                55)
            .clamp(5, 7200);
    _tokenRefreshTimer = Timer(Duration(seconds: seconds), () async {
      final token = await _getAccessToken();
      if (!_disposed && isConnected) {
        if (token == null) {
          _tokenRefreshTimer = Timer(
            const Duration(seconds: 30),
            _scheduleTokenRefresh,
          );
        } else {
          _scheduleTokenRefresh();
        }
      }
    });
  }

  void _loadConfig() {
    _config = _storage.getBotConfig();
    _storage.selectChatAccount(_config.appId);
  }

  void _addLog(String message) {
    _log.info(message);
    onLog?.call('[${DateTime.now().toString().substring(0, 19)}] $message');
  }

  /// Connect to QQ Bot. Returns true on success.
  Future<bool> connect() async {
    if (_isConnecting) return false;
    final attempt = ++_connectionAttempt;
    _isConnecting = true;
    _connectionError = '';
    _connectStep = ConnectStep.idle;
    notifyListeners();

    // Step 1: Get access token
    final token = await _getAccessToken();
    if (_disposed || attempt != _connectionAttempt) return false;
    if (token == null) {
      _connectionStatus = '获取Token失败';
      _connectStep = ConnectStep.done;
      _isConnecting = false;
      notifyListeners();
      return false;
    }

    // Step 2: Get gateway URL
    _connectStep = ConnectStep.gettingGateway;
    notifyListeners();
    _addLog('正在获取网关地址...');

    final gwResult = await _apiService.getGatewayUrl(
      baseUrl: _config.resolvedApiBaseUrl,
      accessToken: token,
    );
    if (_disposed || attempt != _connectionAttempt) return false;

    if (!gwResult.isSuccess) {
      _connectionError = '获取网关失败: ${gwResult.error}';
      _connectionStatus = '获取网关失败';
      _addLog(_connectionError);
      _connectStep = ConnectStep.done;
      _isConnecting = false;
      notifyListeners();
      return false;
    }

    final wsUrl = gwResult.data;
    if (wsUrl == null) {
      _connectionError = '获取网关失败: URL为空';
      _connectionStatus = '获取网关失败';
      _addLog(_connectionError);
      _connectStep = ConnectStep.done;
      _isConnecting = false;
      notifyListeners();
      return false;
    }

    // Step 3: Connect WebSocket
    _connectStep = ConnectStep.connecting;
    notifyListeners();
    _addLog('网关地址获取成功，正在连接 WebSocket...');

    final success = await _wsService.connect(
      wsUrl: wsUrl,
      accessToken: token,
      autoReconnect: _config.autoReconnect,
      reconnectInterval: Duration(seconds: _config.reconnectInterval),
    );
    if (_disposed || attempt != _connectionAttempt) return false;

    _connectStep = ConnectStep.done;
    _isConnecting = false;
    if (success) {
      _connectionError = '';
      _connectionStatus = '在线';
      _scheduleTokenRefresh();
      _addLog('WebSocket 已连接并完成鉴权');
    } else {
      _connectionError = _wsService.lastError.isNotEmpty
          ? _wsService.lastError
          : 'WebSocket 连接失败，请检查网络或防火墙设置';
      _connectionStatus = '连接失败';
      _addLog(_connectionError);
    }
    notifyListeners();
    return success;
  }

  /// Disconnect from QQ Bot.
  void disconnect() {
    _connectionAttempt++;
    _isConnecting = false;
    _tokenRefreshTimer?.cancel();
    _wsService.disconnect();
    _connectionStatus = '已断开';
    _connectionError = '';
    _connectStep = ConnectStep.idle;
    _gatewaySessionId = '';
    _addLog('已断开连接');
    notifyListeners();
  }

  void _handleReady(Map<String, dynamic> data) {
    if (_disposed) return;
    final user = data['user'] as Map<String, dynamic>? ?? {};
    _botId = user['id']?.toString() ?? '';
    _botName = user['username']?.toString() ?? '';
    _botAvatarUrl = firstProfileAvatar([user['avatar'], user['avatar_url']]);
    _gatewaySessionId = data['session_id']?.toString() ?? '';
    _connectionStatus = '在线';
    _scheduleTokenRefresh();
    _addLog('READY: $botDisplayName${_botId.isNotEmpty ? " ($_botId)" : ""}');
    notifyListeners();
    unawaited(_syncBotProfile());
  }

  void _handleDispatchEvent(String eventType, Map<String, dynamic> data) {
    if (_disposed) return;
    _lastEventType = eventType;
    _lastEventAt = DateTime.now();
    if (const [
      'INTERACTION_CREATE',
      'GROUP_ADD_ROBOT',
      'GROUP_MSG_RECEIVE',
      'C2C_MSG_RECEIVE',
      'FRIEND_ADD',
    ].contains(eventType)) {
      final sessionId =
          data['group_openid']?.toString() ??
          data['user_openid']?.toString() ??
          data['openid']?.toString() ??
          '';
      final outerId = data['_eventId']?.toString() ?? '';
      final eventId = outerId.isNotEmpty
          ? outerId
          : (data['id']?.toString() ?? '');
      if (sessionId.isNotEmpty && eventId.isNotEmpty) {
        _replyEvents[sessionId] = (
          id: eventId,
          at: DateTime.now(),
          type: eventType,
        );
        if (!_sessions.any((session) => session.id == sessionId)) {
          unawaited(
            addSession(
              sessionId,
              isGroup: (data['group_openid']?.toString() ?? '').isNotEmpty,
            ),
          );
        }
      }
    }
    if (eventType == 'INTERACTION_CREATE') {
      final type =
          data['type'] ?? (data['data'] is Map ? data['data']['type'] : null);
      final interactionId = data['id']?.toString() ?? '';
      if ((type == 11 || type == 12) &&
          interactionId.isNotEmpty &&
          _acknowledgedInteractions.add(interactionId)) {
        if (_acknowledgedInteractions.length > 1000) {
          _acknowledgedInteractions.remove(_acknowledgedInteractions.first);
        }
        unawaited(_acknowledgeInteraction(interactionId, data));
        _dispatchPluginInteraction(interactionId, data);
      }
    }
    if (eventType == 'GROUP_AT_MESSAGE_CREATE' ||
        eventType == 'GROUP_MESSAGE_CREATE') {
      final groupOpenId = data['group_openid'] ?? data['group_id'] ?? '-';
      _addLog('收到群消息事件: group_openid=$groupOpenId');
    } else if (eventType.startsWith('GROUP_')) {
      _addLog('收到群事件: $eventType');
    }
    notifyListeners();
  }

  String latestReplyEventId(String sessionId) {
    final event = _replyEvents[sessionId];
    return event != null &&
            DateTime.now().difference(event.at) < const Duration(minutes: 5)
        ? event.id
        : '';
  }

  void _dispatchPluginInteraction(String id, Map<String, dynamic> data) {
    final body = data['data'];
    if (body is! Map || body['resolved'] is! Map) return;
    final resolved = body['resolved'] as Map;
    final callback = resolved['button_data']?.toString() ?? '';
    if (!callback.startsWith('qqm:') || callback.length > 512) return;
    if (data['application_id'] != null &&
        data['application_id'].toString() != _config.appId) {
      return;
    }
    final group = data['group_openid']?.toString() ?? '';
    final user = data['user_openid']?.toString() ?? '';
    final actor = group.isNotEmpty
        ? data['group_member_openid']?.toString() ?? ''
        : user;
    final session = group.isNotEmpty ? group : user;
    if (session.isEmpty || actor.isEmpty) return;
    if (!_dispatchedInteractions.add(id)) return;
    if (_dispatchedInteractions.length > 1000) {
      _dispatchedInteractions.remove(_dispatchedInteractions.first);
    }
    final outerId = data['_eventId']?.toString() ?? '';
    final replyEventId = outerId.isEmpty ? id : outerId;
    _replyEvents[session] = (
      id: replyEventId,
      at: DateTime.now(),
      type: 'INTERACTION_CREATE',
    );
    _dispatchForAutoResponse(
      MessageModel(
        id: id,
        sessionId: session,
        senderId: actor,
        senderName: 'QQ 用户',
        content: '',
        messageType: 0,
        timestamp: DateTime.now(),
        extra: {
          'botAppId': _config.appId,
          'isGroup': group.isNotEmpty,
          'pluginEventId': replyEventId,
          'callbackData': callback,
        },
      ),
    );
  }

  Future<void> _acknowledgeInteraction(
    String interactionId,
    Map<String, dynamic> data,
  ) async {
    final epoch = _accountEpoch;
    final token = await _getAccessToken();
    if (token == null || _disposed || epoch != _accountEpoch) return;
    final result = await _apiService.acknowledgeInteraction(
      baseUrl: _config.resolvedApiBaseUrl,
      accessToken: token,
      interactionId: interactionId,
    );
    if (_disposed || epoch != _accountEpoch) return;
    if (!result.isSuccess) _acknowledgedInteractions.remove(interactionId);
    final resolved = data['data'] is Map ? data['data']['resolved'] : null;
    _addLog(
      result.isSuccess
          ? '按钮回调已确认: ${resolved is Map ? resolved['button_data'] ?? interactionId : interactionId}'
          : '按钮回调确认失败: ${result.error}',
    );
  }

  void _putSession(ChatSession session) {
    final index = _sessions.indexWhere((value) => value.id == session.id);
    if (index < 0) {
      _sessions.add(session);
    } else {
      _sessions[index] = session;
    }
    _sessions.sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    unawaited(
      _storage.saveSession(session).catchError((Object _) {
        if (!_disposed) _addLog('会话资料保存失败，请检查本地存储');
      }),
    );
    if (!_disposed) notifyListeners();
  }

  Map<String, String> _knownMember(
    String key,
    String sessionId,
    String senderId,
  ) {
    if (_memberProfiles.containsKey(key)) return _memberProfiles[key]!;
    final history = getMessagesForSession(sessionId).reversed.where(
      (message) => message.senderId == senderId && !message.isFromBot,
    );
    final found = <String, String>{};
    for (final message in history) {
      if (message.extra?['senderNameIsFallback'] == false ||
          !isFallbackProfileName(message.senderName, senderId)) {
        found.putIfAbsent('name', () => message.senderName);
      }
      if (profileAvatar(message.senderAvatarUrl).isNotEmpty) {
        if (!found.containsKey('avatar') ||
            (isQqOpenIdAvatar(found['avatar']!) &&
                !isQqOpenIdAvatar(message.senderAvatarUrl))) {
          found['avatar'] = message.senderAvatarUrl;
        }
      }
      if (message.senderRole.isNotEmpty) {
        found.putIfAbsent('role', () => message.senderRole);
      }
      if (found.length == 3 && !isQqOpenIdAvatar(found['avatar']!)) break;
    }
    _rememberMember(key, found);
    return found;
  }

  void _rememberMember(String key, Map<String, String> fields) {
    final existing = _memberProfiles[key];
    if (existing != null &&
        fields.entries.every((entry) => existing[entry.key] == entry.value)) {
      return;
    }
    _memberProfiles[key] = {...?_memberProfiles[key], ...fields};
    if (_memberProfiles.length > 2000) {
      _memberProfiles.remove(_memberProfiles.keys.first);
    }
  }

  Future<void> refreshSessionProfile(String id, {bool force = false}) {
    final pending = _profileSyncs[id];
    if (pending != null) return pending;
    late final Future<void> future;
    future = _syncSessionProfile(id, force: force).whenComplete(() {
      if (identical(_profileSyncs[id], future)) _profileSyncs.remove(id);
    });
    _profileSyncs[id] = future;
    return future;
  }

  Future<void> _syncSessionProfile(String id, {required bool force}) async {
    final session = _sessions.where((value) => value.id == id).firstOrNull;
    if (_disposed || session == null) return;
    if (session.sessionType == 0) {
      await _syncPrivateProfile(session, force: force);
      return;
    }
    if (!force &&
        session.profileUpdatedAt != null &&
        DateTime.now().difference(session.profileUpdatedAt!) <
            const Duration(hours: 6)) {
      return;
    }
    if (_config.appId.isEmpty || _config.clientSecret.isEmpty) {
      if (session.profileStatus != '配置机器人凭据后自动同步群资料') {
        _putSession(session.copyWith(profileStatus: '配置机器人凭据后自动同步群资料'));
      }
      return;
    }
    final generation = _profileGeneration;
    _putSession(session.copyWith(profileStatus: '正在查询群资料…'));
    final result = await _profileRequests.request(
      kind: 'group',
      key: id,
      force: force,
      load: () async {
        if (_disposed || generation != _profileGeneration) {
          return ApiResult.failure('资料请求已取消');
        }
        final token = await _getAccessToken();
        if (token == null || _disposed || generation != _profileGeneration) {
          return ApiResult.failure('暂时无法获取访问凭证');
        }
        return _apiService.getGroupInfo(
          baseUrl: _config.resolvedApiBaseUrl,
          accessToken: token,
          groupId: id,
        );
      },
    );
    if (_disposed || generation != _profileGeneration) return;
    final current = _sessions.where((value) => value.id == id).firstOrNull;
    if (current == null) return;
    final data = result.data ?? const <String, dynamic>{};
    final responseId = profileName(data['group_openid']);
    if (result.isSuccess && responseId.isNotEmpty && responseId != id) {
      _putSession(
        current.copyWith(
          profileStatus: '群资料返回的 OpenID 不匹配，已忽略',
          profileUpdatedAt: DateTime.now(),
        ),
      );
      return;
    }
    final name = profileName(data['group_name']);
    // Some event/gateway versions provide avatars, but the documented group
    // info response does not promise this field. Never use a member's avatar.
    final avatar = firstProfileAvatar([
      data['group_avatar'],
      data['avatar'],
      data['avatar_url'],
      current.avatarUrl,
    ]);
    final status = !result.isSuccess
        ? (result.errorCode == 11253
              ? '群资料查询未获白名单授权（11253），可申请权限后手动刷新'
              : (result.statusCode == 403
                    ? '群资料访问被拒绝（HTTP 403），请检查权限及代理配置'
                    : '群资料暂未获取，稍后可手动刷新'))
        : [
            name.isNotEmpty ? '群名已同步' : '平台未返回群名',
            avatar.isNotEmpty ? '已有群头像' : '平台未提供群头像',
          ].join('；');
    final keepNewerName =
        current.name != session.name &&
        !isFallbackProfileName(current.name, id, isGroup: true);
    _putSession(
      current.copyWith(
        name: name.isNotEmpty && !keepNewerName ? name : null,
        avatarUrl: avatar.isNotEmpty ? avatar : null,
        profileStatus: status,
        profileUpdatedAt: DateTime.now(),
      ),
    );
    if (!result.isSuccess) _addLog('群资料同步：${result.error ?? status}');
    if (force) {
      final latest = getMessagesForSession(id).reversed
          .where(
            (message) => !message.isBotAuthor && message.senderId.isNotEmpty,
          )
          .firstOrNull;
      if (latest != null) {
        await _syncGroupMember(id, latest.senderId, force: true);
      }
    }
  }

  String _userAvatarStatus(String avatar) => avatar.isEmpty
      ? '暂无用户头像，请检查 AppID 和用户 OpenID'
      : (isQqOpenIdAvatar(avatar) ? '已配置 QQ CDN 用户头像' : '已接收用户头像');

  Future<void> _syncPrivateProfile(
    ChatSession session, {
    required bool force,
  }) async {
    final id = session.id;
    final key = 'user:$id:$id';
    final known = _knownMember(key, id, id);
    final name = firstProfileName([known['name'], session.name]);
    final avatar = userProfileAvatar(_config.appId, id, [
      known['avatar'],
      session.avatarUrl,
    ]);
    final knownName =
        known['name']?.isNotEmpty == true || !isFallbackProfileName(name, id);
    final enabled = _config.enableOiapiNickname;
    final now = DateTime.now();
    final freshNickname =
        session.nicknameSource == 'oiapi' &&
        session.nicknameAppId == _config.appId &&
        session.nicknameUpdatedAt != null &&
        now.difference(session.nicknameUpdatedAt!) < const Duration(hours: 1);
    final recentFailure =
        session.profileStatus.startsWith('OIAPI 昵称查询未完成') &&
        session.nicknameAppId == _config.appId &&
        session.profileUpdatedAt != null &&
        now.difference(session.profileUpdatedAt!) < const Duration(minutes: 5);
    final shouldQuery =
        enabled &&
        session.nicknameSource != 'qq' &&
        (force || !knownName || session.nicknameSource == 'oiapi') &&
        (force || (!freshNickname && !recentFailure));
    final nicknameStatus = shouldQuery
        ? '正在通过 OIAPI 查询昵称…'
        : (enabled && recentFailure
              ? session.profileStatus.split('；').first
              : (session.nicknameSource == 'oiapi'
                    ? '昵称来自 OIAPI${enabled ? '（缓存）' : '（后续查询已关闭）'}'
                    : (knownName ? '已接收用户昵称' : '平台未返回用户昵称（OIAPI 未启用或暂未查询）')));
    final status = '$nicknameStatus；${_userAvatarStatus(avatar)}';
    if (session.profileStatus != status ||
        name != session.name ||
        avatar != session.avatarUrl) {
      _putSession(
        session.copyWith(name: name, avatarUrl: avatar, profileStatus: status),
      );
    }
    if (!shouldQuery) return;

    // OIAPI documents d.author.id, which may differ from a normalized alias.
    final latest = getMessagesForSession(
      id,
    ).reversed.where((message) => !message.isBotAuthor).firstOrNull;
    final author = latest?.rawEvent['author'];
    final openId = firstProfileName([author is Map ? author['id'] : null, id]);
    final appId = _config.appId;
    final generation = _nicknameGeneration;
    final result = await _nicknameRequests.request(
      kind: 'oiapi',
      key: '$appId:$openId',
      force: force,
      load: () {
        if (_disposed ||
            generation != _nicknameGeneration ||
            !_config.enableOiapiNickname) {
          return Future.value(ApiResult.failure('OIAPI 昵称查询已关闭'));
        }
        return _oiapiService.getNickname(appId: appId, openId: openId);
      },
    );
    if (_disposed ||
        generation != _nicknameGeneration ||
        !_config.enableOiapiNickname) {
      return;
    }
    final current = _sessions.where((value) => value.id == id).firstOrNull;
    if (current == null) return;
    if (current.nicknameSource == 'qq') {
      _putSession(
        current.copyWith(
          profileStatus: '已接收用户昵称；${_userAvatarStatus(current.avatarUrl)}',
        ),
      );
      return;
    }
    final nickname = profileName(result.data?['nickname']);
    if (!result.isSuccess ||
        result.data?['openid'] != openId ||
        nickname.isEmpty) {
      _putSession(
        current.copyWith(
          profileStatus:
              'OIAPI 昵称查询未完成：${result.error ?? '返回资料无效'}；${_userAvatarStatus(current.avatarUrl)}',
          profileUpdatedAt: DateTime.now(),
          nicknameAppId: appId,
        ),
      );
      return;
    }
    _rememberMember(key, {'name': nickname});
    _putSession(
      current.copyWith(
        name: nickname,
        nicknameSource: 'oiapi',
        nicknameAppId: appId,
        nicknameUpdatedAt: DateTime.now(),
        profileUpdatedAt: DateTime.now(),
        profileStatus: '昵称来自 OIAPI；${_userAvatarStatus(current.avatarUrl)}',
      ),
    );
    for (final message in getMessagesForSession(
      id,
    ).where((message) => !message.isBotAuthor)) {
      if (_disposed ||
          generation != _nicknameGeneration ||
          !_config.enableOiapiNickname) {
        return;
      }
      if (_sessions
              .where((value) => value.id == id)
              .firstOrNull
              ?.nicknameSource ==
          'qq') {
        break;
      }
      final replaceName =
          isFallbackProfileName(message.senderName, message.senderId) ||
          (current.nicknameSource == 'oiapi' &&
              message.senderName == current.name &&
              message.extra?['senderNameIsFallback'] != false);
      if (!replaceName) continue;
      final updated = message.copyWith(senderName: nickname);
      final index = _messages.indexWhere((value) => value.id == message.id);
      if (index >= 0) _messages[index] = updated;
      await _storage.updateMessage(updated);
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _syncGroupMember(
    String groupId,
    String memberId, {
    bool force = false,
  }) async {
    if (_disposed ||
        _config.appId.isEmpty ||
        _config.clientSecret.isEmpty ||
        (!force && _profileRequests.isDenied('member'))) {
      return;
    }
    final key = 'group:$groupId:$memberId';
    final checked = _memberCheckedAt[key];
    if (!force &&
        checked != null &&
        DateTime.now().difference(checked) < const Duration(hours: 1)) {
      return;
    }
    _memberCheckedAt[key] = DateTime.now();
    if (_memberCheckedAt.length > 2000) {
      _memberCheckedAt.remove(_memberCheckedAt.keys.first);
    }
    final generation = _profileGeneration;
    final knownAtStart = _memberProfiles[key];
    final result = await _profileRequests.request(
      kind: 'member',
      key: '$groupId:$memberId',
      force: force,
      load: () async {
        if (_disposed || generation != _profileGeneration) {
          return ApiResult.failure('资料请求已取消');
        }
        final token = await _getAccessToken();
        if (token == null || _disposed || generation != _profileGeneration) {
          return ApiResult.failure('暂时无法获取访问凭证');
        }
        return _apiService.getGroupMemberInfo(
          baseUrl: _config.resolvedApiBaseUrl,
          accessToken: token,
          groupId: groupId,
          memberId: memberId,
        );
      },
    );
    if (_disposed || generation != _profileGeneration) return;
    if (!result.isSuccess) {
      if (result.errorCode == 11253 || result.statusCode == 403) {
        _addLog('群成员资料查询被拒绝，已停止自动重复查询；请检查 QQ 平台白名单/API 访问权限');
      }
      return;
    }
    final data = result.data ?? const <String, dynamic>{};
    if (profileName(data['member_openid']).isNotEmpty &&
        data['member_openid'] != memberId) {
      return;
    }
    final current = _memberProfiles[key] ?? const <String, String>{};
    final newerName = current['name'] != knownAtStart?['name'];
    final newerAvatar = current['avatar'] != knownAtStart?['avatar'];
    final newerRole = current['role'] != knownAtStart?['role'];
    final name = firstProfileName([
      if (newerName) current['name'],
      data['username'],
      current['name'],
    ]);
    final avatar = firstProfileAvatar([
      if (newerAvatar && !isQqOpenIdAvatar(current['avatar'] ?? ''))
        current['avatar'],
      data['avatar'],
      data['avatar_url'],
      userProfileAvatar(_config.appId, memberId, [current['avatar']]),
    ]);
    final role = firstProfileName([
      if (newerRole) current['role'],
      data['member_role'],
      current['role'],
    ]);
    _rememberMember(key, {
      if (name.isNotEmpty) 'name': name,
      if (avatar.isNotEmpty) 'avatar': avatar,
      if (role.isNotEmpty) 'role': role,
    });
    for (final message in getMessagesForSession(groupId).where(
      (message) => !message.isBotAuthor && message.senderId == memberId,
    )) {
      final updated = message.copyWith(
        senderName:
            isFallbackProfileName(message.senderName, memberId) &&
                name.isNotEmpty
            ? name
            : null,
        senderAvatarUrl:
            (message.senderAvatarUrl.isEmpty ||
                    isQqOpenIdAvatar(message.senderAvatarUrl)) &&
                avatar.isNotEmpty
            ? avatar
            : null,
        senderRole: message.senderRole.isEmpty && role.isNotEmpty ? role : null,
      );
      final index = _messages.indexWhere((value) => value.id == message.id);
      if (index >= 0) _messages[index] = updated;
      await _storage.updateMessage(updated);
      if (_disposed || generation != _profileGeneration) return;
    }
    notifyListeners();
  }

  Future<void> _syncBotProfile() {
    if (_botProfileSync != null) return _botProfileSync!;
    final generation = _profileGeneration;
    late final Future<void> future;
    future =
        (() async {
          final token = await _getAccessToken();
          if (token == null || _disposed || generation != _profileGeneration) {
            return;
          }
          final result = await _apiService.getBotProfile(
            baseUrl: _config.resolvedApiBaseUrl,
            accessToken: token,
          );
          if (_disposed ||
              generation != _profileGeneration ||
              !result.isSuccess) {
            return;
          }
          final data = result.data ?? const <String, dynamic>{};
          _botName = firstProfileName([data['username'], _botName]);
          _botAvatarUrl = firstProfileAvatar([data['avatar'], _botAvatarUrl]);
          for (var i = 0; i < _messages.length; i++) {
            if (_messages[i].isFromBot) {
              final updated = _messages[i].copyWith(
                senderName: _botName.isNotEmpty ? _botName : null,
                senderAvatarUrl: _botAvatarUrl.isNotEmpty
                    ? _botAvatarUrl
                    : null,
              );
              _messages[i] = updated;
              await _storage.updateMessage(updated);
              if (_disposed || generation != _profileGeneration) return;
            }
          }
          notifyListeners();
        })().whenComplete(() {
          if (identical(_botProfileSync, future)) _botProfileSync = null;
        });
    _botProfileSync = future;
    return future;
  }

  void _resetProfileLookups() {
    _resetNicknameLookups();
    _profileGeneration++;
    _profileRequests.dispose();
    _profileRequests = ProfileRequestQueue();
    _profileSyncs.clear();
    _memberProfiles.clear();
    _memberCheckedAt.clear();
    _botProfileSync = null;
    _botAvatarUrl = '';
    _botName = '';
    _botId = '';
  }

  void _resetNicknameLookups() {
    _nicknameGeneration++;
    _nicknameRequests.dispose();
    _nicknameRequests = ProfileRequestQueue();
    _oiapiService.cancelPending();
    _profileSyncs.removeWhere(
      (id, _) => _sessions.any(
        (session) => session.id == id && session.sessionType == 0,
      ),
    );
  }

  void _handleIncomingMessage(Map<String, dynamic> data) {
    if (_disposed) return;
    if (data['_transportGeneration'] != null &&
        data['_transportGeneration'] != _wsService.transportGeneration) {
      return;
    }
    if (data['isRecallEvent'] == true) {
      _handleRecallEvent(data);
      return;
    }

    final sessionId = data['sessionId'] as String? ?? '';
    final senderId = data['senderId'] as String? ?? '';
    final rawSenderName = profileName(data['senderName']);
    final senderLevel = data['senderLevel'] as String? ?? '';
    final senderTitle = data['senderTitle'] as String? ?? '';
    final rawSenderRole = data['senderRole'] as String? ?? '';
    final content = data['content'] as String? ?? '';
    final messageType = data['messageType'] as int? ?? 0;
    final timestamp = data['timestamp'] as DateTime? ?? DateTime.now();
    final isGroup = data['isGroup'] as bool? ?? false;
    final imageUrl = data['imageUrl'] as String?;
    final markdownContent = data['markdownContent'] as String?;
    final eventType = data['eventType'] as String? ?? '';
    if (eventType == 'GROUP_MESSAGE_CREATE' &&
        !_config.receiveAllGroupMessages) {
      return;
    }

    final messageId = data['id'] as String? ?? '';
    if (sessionId.isEmpty || messageId.isEmpty) {
      _addLog('跳过缺少会话 OpenID 或消息 ID 的事件');
      return;
    }
    final profileKey = '${isGroup ? 'group' : 'user'}:$sessionId:$senderId';
    final previous =
        _sessions.where((s) => s.id == sessionId).firstOrNull ??
        _storage.getSessions().where((s) => s.id == sessionId).firstOrNull;
    final known = _knownMember(profileKey, sessionId, senderId);
    final hasName = data['senderNameIsFallback'] == false
        ? rawSenderName.isNotEmpty
        : (data['senderNameIsFallback'] != true &&
              !isFallbackProfileName(rawSenderName, senderId));
    final senderName = hasName ? rawSenderName : known['name'] ?? rawSenderName;
    final senderAvatarUrl = firstProfileAvatar([
      data['senderAvatarUrl'],
      if (data['senderIsBot'] != true &&
          !(data['extra'] is Map &&
              data['extra']['author'] is Map &&
              data['extra']['author']['bot'] == true))
        userProfileAvatar(_config.appId, senderId, [
          known['avatar'],
          if (!isGroup) previous?.avatarUrl,
        ])
      else
        known['avatar'],
    ]);
    final senderRole = firstProfileName([rawSenderRole, known['role']]);
    _rememberMember(profileKey, {
      if (hasName) 'name': rawSenderName,
      if (senderAvatarUrl.isNotEmpty) 'avatar': senderAvatarUrl,
      if (senderRole.isNotEmpty) 'role': senderRole,
    });
    final message = MessageModel(
      id: messageId,
      sessionId: sessionId,
      senderId: senderId,
      senderName: senderName,
      senderAvatarUrl: senderAvatarUrl,
      senderLevel: senderLevel,
      senderTitle: senderTitle,
      senderRole: senderRole,
      content: content,
      messageType: messageType,
      timestamp: timestamp,
      isFromBot: false,
      imageUrl: imageUrl,
      markdownContent: markdownContent,
      extra: {...data, 'botAppId': _config.appId},
    );

    final existing = _messages.where((m) => m.id == messageId).firstOrNull;
    final original = existing ?? _storage.getMessageById(messageId);
    if (original != null) {
      if (original.sessionId == sessionId && original.senderId == senderId) {
        final enriched = original.copyWith(
          senderName: hasName ? senderName : null,
          senderAvatarUrl: senderAvatarUrl.isNotEmpty ? senderAvatarUrl : null,
          senderRole: senderRole.isNotEmpty ? senderRole : null,
        );
        final index = _messages.indexWhere((value) => value.id == messageId);
        if (index >= 0) _messages[index] = enriched;
        unawaited(_storage.updateMessage(enriched));
        final session = _sessions
            .where((value) => value.id == sessionId)
            .firstOrNull;
        if (session != null) {
          final groupName = profileName(data['groupName']);
          final groupAvatar = profileAvatar(data['groupAvatarUrl']);
          _putSession(
            session.copyWith(
              name: isGroup
                  ? (groupName.isNotEmpty ? groupName : null)
                  : (hasName ? senderName : null),
              avatarUrl: isGroup
                  ? (groupAvatar.isNotEmpty ? groupAvatar : null)
                  : (senderAvatarUrl.isNotEmpty ? senderAvatarUrl : null),
              nicknameSource: !isGroup && hasName ? 'qq' : null,
              nicknameUpdatedAt: !isGroup && hasName ? timestamp : null,
            ),
          );
          unawaited(refreshSessionProfile(sessionId));
        }
      }
      // 全量和 @ 事件可能携带相同消息 ID：只保存一次，但不漏掉后到的 @。
      if (existing?.isFullGroupMessage == true &&
          eventType == 'GROUP_AT_MESSAGE_CREATE') {
        _dispatchForAutoResponse(message);
      }
      return;
    }
    if (message.isFullGroupMessage) _fullGroupMessageCount++;
    if (!message.isBotAuthor) {
      _lastInboundMessageIds[sessionId] = message.id;
    }

    _messages.add(message);
    _storage.saveMessage(message);

    final groupName = profileName(data['groupName']);
    final groupAvatar = profileAvatar(data['groupAvatarUrl']);
    final name = isGroup
        ? firstProfileName([groupName, previous?.name, '群聊-$sessionId'])
        : firstProfileName([
            hasName || known['name']?.isNotEmpty == true ? senderName : null,
            previous?.name,
            senderName,
            '用户-$sessionId',
          ]);
    final avatar = isGroup
        ? firstProfileAvatar([groupAvatar, previous?.avatarUrl])
        : firstProfileAvatar([senderAvatarUrl, previous?.avatarUrl]);
    _putSession(
      ChatSession(
        id: sessionId,
        name: name,
        avatarUrl: avatar,
        sessionType: isGroup ? 1 : 0,
        lastMessageTime: timestamp,
        lastMessage: message.sessionPreview,
        unreadCount: (previous?.unreadCount ?? 0) + 1,
        isPinned: previous?.isPinned ?? false,
        profileStatus: previous?.profileStatus ?? '',
        profileUpdatedAt: previous?.profileUpdatedAt,
        nicknameSource: !isGroup && hasName
            ? 'qq'
            : previous?.nicknameSource ?? '',
        nicknameAppId: previous?.nicknameAppId ?? '',
        nicknameUpdatedAt: !isGroup && hasName
            ? timestamp
            : previous?.nicknameUpdatedAt,
      ),
    );
    unawaited(refreshSessionProfile(sessionId));
    if (isGroup && !hasName && !message.isBotAuthor && senderId.isNotEmpty) {
      unawaited(_syncGroupMember(sessionId, senderId));
    }

    _dispatchForAutoResponse(message);
    final preview = message.sessionPreview;
    _addLog(
      '收到消息 [${isGroup ? "群聊" : "好友"}${eventType.isNotEmpty ? "/$eventType" : ""}] $senderName: ${preview.length > 50 ? '${preview.substring(0, 50)}...' : preview}',
    );
    notifyListeners();
  }

  void _dispatchForAutoResponse(MessageModel message) {
    if (onMessageReceived == null || !shouldAutoRespondTo(message)) {
      return;
    }
    final previous =
        _pendingPluginDispatches[message.id] ?? Future<void>.value();
    final appId = _config.appId;
    final epoch = _accountEpoch;
    late final Future<void> pending;
    pending = previous
        .then((_) async {
          if (_disposed ||
              _config.appId != appId ||
              epoch != _accountEpoch ||
              _autoDispatchedMessageIds.contains(message.id)) {
            return;
          }
          // The host returns false when a full-group event did not match a plugin.
          // A later @ delivery of the same message can then run a mention-only rule.
          final handled = await onMessageReceived?.call(message);
          if (handled != false && epoch == _accountEpoch && !_disposed) {
            if (_autoDispatchedMessageIds.length >= 4000) {
              _autoDispatchedMessageIds.remove(_autoDispatchedMessageIds.first);
            }
            _autoDispatchedMessageIds.add(message.id);
          }
        })
        .catchError((Object _) {
          _addLog('插件消息处理失败，请查看插件中心状态。');
        })
        .whenComplete(() {
          if (identical(_pendingPluginDispatches[message.id], pending)) {
            _pendingPluginDispatches.remove(message.id);
          }
        });
    _pendingPluginDispatches[message.id] = pending;
  }

  Future<void> _handleRecallEvent(Map<String, dynamic> data) async {
    final epoch = _accountEpoch;
    final messageId = data['id'] as String? ?? '';
    final sessionId = data['sessionId'] as String? ?? '';
    final senderId = data['senderId'] as String? ?? '';
    final senderName = data['senderName'] as String? ?? '用户';
    final timestamp = data['timestamp'] as DateTime? ?? DateTime.now();
    final eventType = data['eventType'] as String? ?? 'MESSAGE_RECALL';

    MessageModel? original;
    final memoryIndex = _messages.indexWhere((m) => m.id == messageId);
    if (memoryIndex >= 0) original = _messages[memoryIndex];
    original ??= _storage.getMessageById(messageId);

    final recalled = original != null
        ? original.copyWith(isRecalled: true)
        : MessageModel(
            id: messageId.isNotEmpty ? messageId : generateId(),
            sessionId: sessionId,
            senderId: senderId,
            senderName: senderName,
            senderAvatarUrl: data['senderAvatarUrl'] as String? ?? '',
            senderLevel: data['senderLevel'] as String? ?? '',
            senderTitle: data['senderTitle'] as String? ?? '',
            senderRole: data['senderRole'] as String? ?? '',
            content: '',
            messageType: 0,
            timestamp: timestamp,
            isFromBot: false,
            isRecalled: true,
            extra: data,
          );

    final index = _messages.indexWhere((m) => m.id == recalled.id);
    if (index >= 0) {
      _messages[index] = recalled;
    } else {
      _messages.add(recalled);
    }
    await _storage.updateMessage(recalled);
    if (_disposed || epoch != _accountEpoch) return;

    final targetSessionId = recalled.sessionId.isNotEmpty
        ? recalled.sessionId
        : sessionId;
    if (targetSessionId.isNotEmpty) {
      await _storage.updateSessionLastMessage(
        targetSessionId,
        recalled.isFromBot ? '[你撤回了一条消息]' : '[${recalled.senderName} 撤回了一条消息]',
        DateTime.now(),
        incrementUnread: !recalled.isFromBot,
      );
      _loadSessions();
    }

    _addLog(
      '收到撤回事件 $eventType: ${messageId.isNotEmpty ? messageId : "(无消息ID)"}',
    );
    notifyListeners();
  }

  Map<String, dynamic> previewConfiguredMessage(
    String targetId,
    OutgoingMessage message, {
    bool isGroup = false,
    MessageModel? replyTo,
  }) {
    final error = message.validate(isGroup: isGroup);
    if (error != null) throw FormatException(error);
    final context = _configuredContext(
      targetId,
      message.options,
      isGroup: isGroup,
      replyTo: replyTo,
      reserve: false,
    );
    if (context == null) throw FormatException(_lastSendError);
    return message.toPayload(
      messageId: context.messageId,
      eventId: context.eventId,
      sequence: context.sequence,
      referenceId: context.referenceId,
    );
  }

  Future<bool> sendConfiguredMessage(
    String targetId,
    OutgoingMessage message, {
    bool isGroup = false,
    MessageModel? replyTo,
  }) async {
    final epoch = _accountEpoch;
    final error = message.validate(isGroup: isGroup);
    if (error != null) {
      _setSendError(error);
      return false;
    }
    final token = await _prepareSend(targetId);
    if (token == null || _disposed || epoch != _accountEpoch) return false;
    final context = _configuredContext(
      targetId,
      message.options,
      isGroup: isGroup,
      replyTo: replyTo,
      reserve: true,
    );
    if (context == null) return false;
    final result = await _apiService.sendConfiguredMessage(
      baseUrl: _config.resolvedApiBaseUrl,
      accessToken: token,
      targetId: targetId,
      message: message,
      isGroup: isGroup,
      msgId: context.messageId,
      eventId: context.eventId,
      msgSeq: context.sequence,
      referenceId: context.referenceId,
    );
    if (_disposed || epoch != _accountEpoch) return false;
    if (!result.isSuccess) {
      _setSendError(result.error ?? '消息发送失败');
      return false;
    }
    final mediaName = message.mediaSource.isNotEmpty
        ? message.mediaSource.split(RegExp(r'[/\\]')).last
        : '已上传的媒体';
    addLocalBotMessage(
      targetId,
      message.type == 7
          ? '[${const {1: '图片', 2: '视频', 3: '语音', 4: '文件'}[message.mediaFileType]}] $mediaName'
          : message.content,
      message.type,
      messageId: result.data,
      markdown: message.type == 2 ? message.content : null,
      imageUrl:
          message.type == 7 &&
              message.mediaFileType == 1 &&
              message.mediaSource.isNotEmpty
          ? message.mediaSource
          : null,
      extra: {
        'replyMessageId': context.messageId,
        'replyEventId': context.eventId,
        'replySequence': context.sequence,
        'referenceId': context.referenceId,
        if (message.options.keyboard != null)
          'keyboard': message.options.keyboard!.toJson(),
        if (message.type == 7) 'mediaFileType': message.mediaFileType,
        if (result.metadata != null) 'response': result.metadata,
      },
    );
    _addLog(
      '消息已发送（类型 ${message.type}${message.options.keyboard == null ? '' : '，含按钮键盘'}）',
    );
    return true;
  }

  ({String messageId, String eventId, int? sequence, String referenceId})?
  _configuredContext(
    String sessionId,
    MessageSendOptions options, {
    required bool isGroup,
    MessageModel? replyTo,
    required bool reserve,
  }) {
    if (replyTo != null && !_ownsMessage(replyTo)) {
      _setSendError('引用消息不属于当前 AppID，请重新选择');
      return null;
    }
    var messageId = '';
    var eventId = '';
    int? sequence;
    switch (options.replyMode) {
      case ReplyMode.automatic:
        final context = _replyContext(
          sessionId,
          isGroup,
          replyTo?.isFromBot == true ? null : replyTo,
          reserveSequence: false,
        );
        if (context == null) return null;
        messageId = context.messageId ?? '';
        sequence = context.sequence;
      case ReplyMode.message:
        messageId = options.messageId.trim();
        final known = getMessagesForSession(
          sessionId,
        ).where((m) => m.id == messageId).firstOrNull;
        if (known != null) {
          final context = _replyContext(
            sessionId,
            isGroup,
            known,
            reserveSequence: false,
          );
          if (context == null) return null;
          sequence = context.sequence;
        } else {
          sequence = _nextReplySeq(sessionId, messageId, reserve: false);
        }
      case ReplyMode.event:
        eventId = options.eventId.trim();
        final key = '$sessionId:event:$eventId';
        var current = _replySequences[key] ?? 0;
        for (final sent in getMessagesForSession(sessionId)) {
          if (sent.extra?['replyEventId'] == eventId) {
            final stored = sent.extra?['replySequence'] as int? ?? 0;
            if (stored > current) current = stored;
          }
        }
        sequence = current + 1;
      case ReplyMode.active:
        break;
    }
    if (options.sequence != null) {
      if (messageId.isEmpty && eventId.isEmpty) {
        _setSendError('没有可回复的消息或事件，无法指定回复序号');
        return null;
      }
      if (options.sequence! < (sequence ?? 1)) {
        _setSendError('该回复序号已使用，请使用 ${sequence ?? 1} 或更大的序号');
        return null;
      }
      sequence = options.sequence;
    }
    if (reserve && sequence != null) {
      _replySequences[eventId.isNotEmpty
              ? '$sessionId:event:$eventId'
              : '$sessionId:$messageId'] =
          sequence;
    }
    if (replyTo != null && replyTo.sessionId != sessionId) {
      _setSendError('引用消息必须属于当前会话');
      return null;
    }
    final referenceId = options.referenceId.trim().isNotEmpty
        ? options.referenceId.trim()
        : (options.quoteSelectedMessage ? replyTo?.referenceIndex ?? '' : '');
    return (
      messageId: messageId,
      eventId: eventId,
      sequence: sequence,
      referenceId: referenceId,
    );
  }

  Future<bool> sendTextMessage(
    String targetId,
    String content, {
    bool isGroup = false,
    MessageModel? replyTo,
  }) async {
    final epoch = _accountEpoch;
    final token = await _prepareSend(targetId);
    if (token == null || _disposed || epoch != _accountEpoch) return false;
    final reply = _replyContext(targetId, isGroup, replyTo);
    if (reply == null) return false;
    final result = await _apiService.sendQQMessage(
      baseUrl: _config.resolvedApiBaseUrl,
      accessToken: token,
      targetId: targetId,
      content: content,
      isGroup: isGroup,
      msgId: reply.messageId,
      msgSeq: reply.sequence,
    );
    if (_disposed || epoch != _accountEpoch) return false;
    if (result.isSuccess) {
      _saveSentMessage(
        targetId,
        content,
        0,
        messageId: result.data,
        imageUrl: null,
        replyMessageId: reply.messageId,
        replySequence: reply.sequence,
        responseMetadata: result.metadata,
      );
      _addLog('发送消息: $content');
      return true;
    }
    _setSendError(result.error ?? '消息发送失败');
    return false;
  }

  Future<bool> sendMarkdownMessage(
    String targetId,
    String markdown, {
    bool isGroup = false,
    MessageModel? replyTo,
    bool useTemplate = false,
    String? templateId,
    List<Map<String, String>>? templateParams,
  }) async {
    final epoch = _accountEpoch;
    final token = await _prepareSend(targetId);
    if (token == null || _disposed || epoch != _accountEpoch) return false;
    final reply = _replyContext(targetId, isGroup, replyTo);
    if (reply == null) return false;
    final effectiveTemplateId = useTemplate
        ? (templateId ?? _config.markdownTemplateId)
        : null;
    final effectiveParams = useTemplate
        ? (templateParams ?? _config.markdownTemplateParams)
        : null;

    final result = await _apiService.sendQQMarkdown(
      baseUrl: _config.resolvedApiBaseUrl,
      accessToken: token,
      targetId: targetId,
      markdownContent: useTemplate ? null : markdown,
      templateId: effectiveTemplateId,
      templateParams: effectiveParams,
      isGroup: isGroup,
      msgId: reply.messageId,
      msgSeq: reply.sequence,
    );
    if (_disposed || epoch != _accountEpoch) return false;
    if (result.isSuccess) {
      _saveSentMessage(
        targetId,
        useTemplate ? '[Markdown模板]' : '[Markdown]',
        2,
        messageId: result.data,
        markdown: markdown,
        replyMessageId: reply.messageId,
        replySequence: reply.sequence,
        responseMetadata: result.metadata,
      );
      _addLog(useTemplate ? '发送Markdown模板消息' : '发送Markdown消息');
      return true;
    }
    if (!useTemplate &&
        (result.errorCode == 40034011 || result.errorCode == 40034124) &&
        (markdown.contains('```') || markdown.contains('~~~'))) {
      _addLog('平台拒绝了代码块 Markdown 格式，正在保留原文改用普通文本发送');
      return sendTextMessage(
        targetId,
        markdown,
        isGroup: isGroup,
        replyTo: replyTo,
      );
    }
    _setSendError(result.error ?? 'Markdown 发送失败');
    return false;
  }

  Future<bool> sendImageMessage(
    String targetId,
    String imageUrl, {
    bool isGroup = false,
    MessageModel? replyTo,
  }) async {
    final epoch = _accountEpoch;
    final token = await _prepareSend(targetId);
    if (token == null || _disposed || epoch != _accountEpoch) return false;
    final reply = _replyContext(targetId, isGroup, replyTo);
    if (reply == null) return false;
    final result = await _apiService.sendQQImage(
      baseUrl: _config.resolvedApiBaseUrl,
      accessToken: token,
      targetId: targetId,
      imageUrl: imageUrl,
      isGroup: isGroup,
      msgId: reply.messageId,
      msgSeq: reply.sequence,
    );
    if (_disposed || epoch != _accountEpoch) return false;
    if (result.isSuccess) {
      _saveSentMessage(
        targetId,
        '[图片消息]',
        7,
        messageId: result.data,
        imageUrl: imageUrl,
        replyMessageId: reply.messageId,
        replySequence: reply.sequence,
        responseMetadata: result.metadata,
      );
      _addLog('发送图片: $imageUrl');
      return true;
    }
    _setSendError(result.error ?? '图片发送失败');
    return false;
  }

  void _saveSentMessage(
    String targetId,
    String content,
    int type, {
    String? messageId,
    String? imageUrl,
    String? markdown,
    String? replyMessageId,
    int? replySequence,
    Map<String, dynamic>? responseMetadata,
  }) {
    addLocalBotMessage(
      targetId,
      content,
      type,
      messageId: messageId,
      imageUrl: imageUrl,
      markdown: markdown,
      extra: {
        'replyMessageId': replyMessageId,
        'replySequence': replySequence,
        'response': ?responseMetadata,
      },
    );
  }

  /// Add a bot message to the local chat display without sending via QQ API.
  /// Used for plugin results and local-only operations.
  void addLocalBotMessage(
    String targetId,
    String content,
    int type, {
    String? messageId,
    String? imageUrl,
    String? markdown,
    Map<String, dynamic>? extra,
  }) {
    final msg = MessageModel(
      id: (messageId != null && messageId.isNotEmpty)
          ? messageId
          : generateId(),
      sessionId: targetId,
      senderId: 'bot',
      senderName: _botName.isNotEmpty ? _botName : '机器人',
      senderAvatarUrl: _botAvatarUrl,
      content: content,
      messageType: type,
      timestamp: DateTime.now(),
      isFromBot: true,
      isRead: true,
      imageUrl: imageUrl,
      markdownContent: markdown,
      extra: {
        ...(extra ?? {'localOnly': true}),
        'botAppId': _config.appId,
      },
    );
    _messages.add(msg);
    _storage.saveMessage(msg);
    _storage.updateSessionLastMessage(
      targetId,
      content.isNotEmpty ? content : '[消息]',
      DateTime.now(),
      incrementUnread: false,
    );
    _loadSessions();
    notifyListeners();
  }

  bool canRecallMessage(MessageModel message) {
    return message.isFromBot &&
        _ownsMessage(message) &&
        !message.isRecalled &&
        message.extra?['localOnly'] != true &&
        DateTime.now().difference(message.timestamp) <=
            const Duration(minutes: 2);
  }

  Future<bool> recallMessage(MessageModel message) async {
    final epoch = _accountEpoch;
    if (!canRecallMessage(message)) {
      _addLog('撤回失败: 只能撤回机器人 2 分钟内发送的消息');
      return false;
    }
    final token = await _prepareSend(message.sessionId);
    if (token == null || _disposed || epoch != _accountEpoch) return false;
    ChatSession? session;
    for (final item in _sessions) {
      if (item.id == message.sessionId) {
        session = item;
        break;
      }
    }
    final result = await _apiService.recallMessage(
      baseUrl: _config.resolvedApiBaseUrl,
      accessToken: token,
      targetId: message.sessionId,
      messageId: message.id,
      isGroup: session?.sessionType == 1,
    );
    if (_disposed || epoch != _accountEpoch) return false;
    if (result.isSuccess) {
      final recalled = message.copyWith(isRecalled: true);
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index >= 0) {
        _messages[index] = recalled;
      } else {
        _messages.add(recalled);
      }
      await _storage.updateMessage(recalled);
      if (_disposed || epoch != _accountEpoch) return false;
      await _storage.updateSessionLastMessage(
        message.sessionId,
        '[你撤回了一条消息]',
        DateTime.now(),
        incrementUnread: false,
      );
      _loadSessions();
      _addLog('已撤回消息: ${message.id}');
      notifyListeners();
      return true;
    }
    _setSendError(result.error ?? '撤回失败');
    return false;
  }

  int? _nextReplySeq(
    String sessionId,
    String? replyMessageId, {
    bool reserve = true,
  }) {
    if (replyMessageId == null || replyMessageId.isEmpty) return null;
    final key = '$sessionId:$replyMessageId';
    var current = _replySequences[key] ?? 0;
    for (final message in getMessagesForSession(sessionId)) {
      if (message.isFromBot &&
          message.extra?['replyMessageId'] == replyMessageId) {
        final sequence = message.extra?['replySequence'] as int? ?? 0;
        if (sequence > current) current = sequence;
      }
    }
    final next = current + 1;
    if (reserve) _replySequences[key] = next;
    return next;
  }

  Future<String?> _prepareSend(String targetId) async {
    _lastSendError = '';
    if (targetId.trim().isEmpty) {
      _setSendError('会话 OpenID 不能为空');
      return null;
    }
    final epoch = _accountEpoch;
    final token = await _getAccessToken();
    if (_disposed || epoch != _accountEpoch) return null;
    if (token == null) {
      _setSendError(
        _connectionError.isEmpty ? '未获取到访问凭证，请先配置并连接机器人' : _connectionError,
      );
    }
    return token;
  }

  ({String? messageId, int? sequence})? _replyContext(
    String sessionId,
    bool isGroup,
    MessageModel? replyTo, {
    bool reserveSequence = true,
  }) {
    final history = getMessagesForSession(sessionId);
    MessageModel? inbound = replyTo;
    if (inbound != null && !_ownsMessage(inbound)) {
      _setSendError('回复消息不属于当前 AppID，请重新选择');
      return null;
    }
    if (inbound != null &&
        (inbound.isFromBot ||
            inbound.isRecalled ||
            inbound.sessionId != sessionId)) {
      _setSendError('请选择当前会话中对方发送且未撤回的消息作为回复来源');
      return null;
    }
    if (inbound == null) {
      final lastId = _lastInboundMessageIds[sessionId];
      final received = history
          .where((m) => !m.isBotAuthor && !m.isRecalled && m.id.isNotEmpty)
          .toList();
      if (received.isNotEmpty) {
        inbound =
            received.where((m) => m.id == lastId).firstOrNull ?? received.last;
      }
    }
    final lifetime = Duration(minutes: isGroup ? 5 : 60);
    if (inbound != null &&
        DateTime.now().difference(inbound.timestamp) >= lifetime) {
      if (replyTo != null) {
        _setSendError('所选消息已超过${isGroup ? 5 : 60}分钟回复期限，请选择新消息');
        return null;
      }
      inbound = null;
    }
    if (inbound != null) {
      final count = history
          .where(
            (m) => m.isFromBot && m.extra?['replyMessageId'] == inbound!.id,
          )
          .length;
      if (count >= (isGroup ? 5 : 4)) {
        _setSendError('这条消息的回复次数已用完，请等待对方发送新消息');
        return null;
      }
    }
    return (
      messageId: inbound?.id,
      sequence: _nextReplySeq(sessionId, inbound?.id, reserve: reserveSequence),
    );
  }

  void _setSendError(String error) {
    _lastSendError = error;
    _addLog('发送失败: $error');
    notifyListeners();
  }

  Future<void> updateConfig(BotConfig newConfig) {
    final pending = _configWrites.then((_) => _applyConfig(newConfig));
    _configWrites = pending.catchError((Object _) {});
    return pending;
  }

  Future<void> _applyConfig(BotConfig newConfig) async {
    _configRevision++;
    final nicknameSettingChanged =
        _config.enableOiapiNickname != newConfig.enableOiapiNickname;
    final credentialsChanged =
        _config.appId != newConfig.appId ||
        _config.clientSecret != newConfig.clientSecret;
    if (credentialsChanged) {
      newConfig.accessToken = '';
      newConfig.tokenExpiresAt = 0;
    } else {
      newConfig.accessToken = _config.accessToken;
      newConfig.tokenExpiresAt = _config.tokenExpiresAt;
    }
    // Do not disconnect or replace working credentials if persistence fails.
    await _storage.saveBotConfig(newConfig);
    final accountChanged = _config.appId != newConfig.appId;
    if (credentialsChanged) {
      _accountEpoch++;
      _messages.clear();
      _sessions.clear();
      _lastInboundMessageIds.clear();
      _replySequences.clear();
      _replyEvents.clear();
      _acknowledgedInteractions.clear();
      _dispatchedInteractions.clear();
      _autoDispatchedMessageIds.clear();
      _pendingPluginDispatches.clear();
      _fullGroupMessageCount = 0;
      _lastEventType = '';
      _lastEventAt = null;
      _lastHeartbeatAckAt = null;
      _lastSendError = '';
      _resetProfileLookups();
      disconnect();
      _tokenRequest = null;
    } else if (nicknameSettingChanged) {
      _resetNicknameLookups();
    }
    _config = newConfig;
    _storage.selectChatAccount(newConfig.appId);
    if (credentialsChanged) _loadSessions();
    _addLog(accountChanged ? '已切换机器人 AppID：${newConfig.appId}' : '配置已更新');
    notifyListeners();
  }

  void _loadSessions() {
    final stored = _storage.getSessions();
    _sessions
      ..clear()
      ..addAll(
        stored.map((session) {
          if (session.sessionType != 0) return session;
          final avatar = userProfileAvatar(_config.appId, session.id, [
            session.avatarUrl,
          ]);
          return avatar == session.avatarUrl
              ? session
              : session.copyWith(avatarUrl: avatar);
        }),
      );
    notifyListeners();
  }

  MessageModel _withUserAvatar(MessageModel message) {
    if (message.extra?['botAppId'] == null) {
      message = message.copyWith(
        extra: {...?message.extra, 'botAppId': _config.appId},
      );
    }
    if (message.isBotAuthor) return message;
    final avatar = userProfileAvatar(_config.appId, message.senderId, [
      message.senderAvatarUrl,
    ]);
    return avatar == message.senderAvatarUrl
        ? message
        : message.copyWith(senderAvatarUrl: avatar);
  }

  List<MessageModel> getMessagesForSession(String sessionId) {
    final byId = <String, MessageModel>{};
    for (final message in _storage.getMessages(sessionId)) {
      byId[message.id] = message;
    }
    for (final message in _messages.where((m) => m.sessionId == sessionId)) {
      byId[message.id] = message;
    }
    final messages = byId.values.map(_withUserAvatar).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  Future<void> markSessionRead(String sessionId) async {
    final epoch = _accountEpoch;
    final session = _sessions
        .where((value) => value.id == sessionId)
        .firstOrNull;
    if (session != null) _putSession(session.copyWith(unreadCount: 0));
    await _storage.markSessionRead(sessionId);
    if (_disposed || epoch != _accountEpoch) return;
    _loadSessions();
  }

  Future<void> addSession(
    String openId, {
    required bool isGroup,
    String name = '',
  }) async {
    final epoch = _accountEpoch;
    final id = openId.trim();
    if (id.isEmpty || _sessions.any((s) => s.id == id)) return;
    await _storage.saveSession(
      ChatSession(
        id: id,
        name: name.trim().isEmpty
            ? '${isGroup ? '群聊' : '用户'}-$id'
            : name.trim(),
        sessionType: isGroup ? 1 : 0,
        lastMessageTime: DateTime.now(),
      ),
    );
    if (_disposed || epoch != _accountEpoch) return;
    _loadSessions();
    unawaited(refreshSessionProfile(id));
  }

  void clearError() {
    _connectionError = '';
    notifyListeners();
  }

  void refresh() {
    _loadConfig();
    _loadSessions();
    notifyListeners();
  }

  void resetLocalState() {
    _accountEpoch++;
    _configRevision++;
    _resetProfileLookups();
    _messages.clear();
    _lastInboundMessageIds.clear();
    _replySequences.clear();
    _replyEvents.clear();
    _acknowledgedInteractions.clear();
    _dispatchedInteractions.clear();
    _pendingPluginDispatches.clear();
    _autoDispatchedMessageIds.clear();
    _fullGroupMessageCount = 0;
    _loadConfig();
    _loadSessions();
  }

  @override
  void dispose() {
    _disposed = true;
    _profileRequests.dispose();
    _nicknameRequests.dispose();
    _oiapiService.dispose();
    _tokenRefreshTimer?.cancel();
    _wsService.dispose();
    super.dispose();
  }
}
