import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import '../models/message.dart';
import '../models/config.dart';
import '../models/outgoing_message.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../services/storage_service.dart';
import '../utils/helpers.dart';

enum ConnectStep { idle, gettingToken, gettingGateway, connecting, done }

class BotClient extends ChangeNotifier {
  final Logger _log = Logger('BotClient');
  final StorageService _storage;
  final ApiService _apiService;
  final WebSocketService _wsService;

  BotConfig _config = BotConfig();
  final List<MessageModel> _messages = [];
  final List<ChatSession> _sessions = [];
  final Map<String, String> _lastInboundMessageIds = {};
  final Map<String, int> _replySequences = {};
  final Map<String, ({String id, DateTime at, String type})> _replyEvents = {};
  final Set<String> _acknowledgedInteractions = {};
  final Set<String> _autoDispatchedMessageIds = {};
  int _fullGroupMessageCount = 0;
  Future<String?>? _tokenRequest;
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
  }) : _apiService = apiService ?? ApiService(),
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
  List<MessageModel> get messages => List.unmodifiable(_messages);
  List<ChatSession> get sessions => _sessions;
  String get botId => _botId;
  String get botName => _botName;
  String get gatewaySessionId => _gatewaySessionId;
  String get lastEventType => _lastEventType;
  DateTime? get lastEventAt => _lastEventAt;
  DateTime? get lastHeartbeatAckAt => _lastHeartbeatAckAt;
  int get heartbeatIntervalMs => _heartbeatIntervalMs;
  int get fullGroupMessageCount => _fullGroupMessageCount;
  bool shouldAutoRespondTo(MessageModel message) =>
      !message.isBotAuthor &&
      !message.isRecalled &&
      (!message.isFullGroupMessage || _config.autoReplyToAllGroupMessages);
  String get botDisplayName => _botName.isNotEmpty ? _botName : '未获取机器人资料';

  /// Get a valid access token, refreshing if expired.
  Future<String?> _getAccessToken() {
    if (!_config.isTokenExpired) return Future.value(_config.accessToken);
    return _tokenRequest ??= _refreshAccessToken().whenComplete(
      () => _tokenRequest = null,
    );
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
    final result = await _apiService.getAccessToken(
      appId: requestedConfig.appId,
      clientSecret: requestedConfig.clientSecret,
    );
    if (_disposed || !identical(requestedConfig, _config)) return null;

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
    _gatewaySessionId = data['session_id']?.toString() ?? '';
    _connectionStatus = '在线';
    _scheduleTokenRefresh();
    _addLog('READY: $botDisplayName${_botId.isNotEmpty ? " ($_botId)" : ""}');
    notifyListeners();
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

  Future<void> _acknowledgeInteraction(
    String interactionId,
    Map<String, dynamic> data,
  ) async {
    final token = await _getAccessToken();
    if (token == null || _disposed) return;
    final result = await _apiService.acknowledgeInteraction(
      baseUrl: _config.resolvedApiBaseUrl,
      accessToken: token,
      interactionId: interactionId,
    );
    if (_disposed) return;
    if (!result.isSuccess) _acknowledgedInteractions.remove(interactionId);
    final resolved = data['data'] is Map ? data['data']['resolved'] : null;
    _addLog(
      result.isSuccess
          ? '按钮回调已确认: ${resolved is Map ? resolved['button_data'] ?? interactionId : interactionId}'
          : '按钮回调确认失败: ${result.error}',
    );
  }

  void _handleIncomingMessage(Map<String, dynamic> data) {
    if (_disposed) return;
    if (data['isRecallEvent'] == true) {
      _handleRecallEvent(data);
      return;
    }

    final sessionId = data['sessionId'] as String? ?? '';
    final senderId = data['senderId'] as String? ?? '';
    final senderName = data['senderName'] as String? ?? '';
    final senderAvatarUrl = data['senderAvatarUrl'] as String? ?? '';
    final senderLevel = data['senderLevel'] as String? ?? '';
    final senderTitle = data['senderTitle'] as String? ?? '';
    final senderRole = data['senderRole'] as String? ?? '';
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
      extra: data,
    );

    final existing = _messages.where((m) => m.id == messageId).firstOrNull;
    if (existing != null || _storage.getMessageById(messageId) != null) {
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

    final existingSession = _sessions.where((s) => s.id == sessionId);
    if (existingSession.isNotEmpty) {
      _storage.updateSessionLastMessage(
        sessionId,
        message.sessionPreview,
        timestamp,
      );
      _loadSessions();
    } else {
      final session = ChatSession(
        id: sessionId,
        name: isGroup ? '群聊-$sessionId' : senderName,
        sessionType: isGroup ? 1 : 0,
        lastMessageTime: timestamp,
        lastMessage: message.sessionPreview,
        unreadCount: 1,
      );
      _storage.saveSession(session);
      _sessions.insert(0, session);
    }

    _dispatchForAutoResponse(message);
    final preview = message.sessionPreview;
    _addLog(
      '收到消息 [${isGroup ? "群聊" : "好友"}${eventType.isNotEmpty ? "/$eventType" : ""}] $senderName: ${preview.length > 50 ? '${preview.substring(0, 50)}...' : preview}',
    );
    notifyListeners();
  }

  void _dispatchForAutoResponse(MessageModel message) {
    if (onMessageReceived == null ||
        !shouldAutoRespondTo(message) ||
        !_autoDispatchedMessageIds.add(message.id)) {
      return;
    }
    onMessageReceived?.call(message);
  }

  Future<void> _handleRecallEvent(Map<String, dynamic> data) async {
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
    final error = message.validate(isGroup: isGroup);
    if (error != null) {
      _setSendError(error);
      return false;
    }
    final token = await _prepareSend(targetId);
    if (token == null) return false;
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
    final token = await _prepareSend(targetId);
    if (token == null) return false;
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
    final token = await _prepareSend(targetId);
    if (token == null) return false;
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
    final token = await _prepareSend(targetId);
    if (token == null) return false;
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
      senderAvatarUrl: '',
      content: content,
      messageType: type,
      timestamp: DateTime.now(),
      isFromBot: true,
      isRead: true,
      imageUrl: imageUrl,
      markdownContent: markdown,
      extra: extra ?? {'localOnly': true},
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
        !message.isRecalled &&
        message.extra?['localOnly'] != true &&
        DateTime.now().difference(message.timestamp) <=
            const Duration(minutes: 2);
  }

  Future<bool> recallMessage(MessageModel message) async {
    if (!canRecallMessage(message)) {
      _addLog('撤回失败: 只能撤回机器人 2 分钟内发送的消息');
      return false;
    }
    final token = await _prepareSend(message.sessionId);
    if (token == null) return false;
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
    if (result.isSuccess) {
      final recalled = message.copyWith(isRecalled: true);
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index >= 0) {
        _messages[index] = recalled;
      } else {
        _messages.add(recalled);
      }
      await _storage.updateMessage(recalled);
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
    final token = await _getAccessToken();
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

  Future<void> updateConfig(BotConfig newConfig) async {
    final credentialsChanged =
        _config.appId != newConfig.appId ||
        _config.clientSecret != newConfig.clientSecret;
    if (credentialsChanged) {
      disconnect();
      newConfig.accessToken = '';
      newConfig.tokenExpiresAt = 0;
    } else {
      newConfig.accessToken = _config.accessToken;
      newConfig.tokenExpiresAt = _config.tokenExpiresAt;
    }
    _config = newConfig;
    await _storage.saveBotConfig(_config);
    _addLog('配置已更新');
    notifyListeners();
  }

  void _loadSessions() {
    final stored = _storage.getSessions();
    _sessions
      ..clear()
      ..addAll(stored);
    notifyListeners();
  }

  List<MessageModel> getMessagesForSession(String sessionId) {
    final byId = <String, MessageModel>{};
    for (final message in _storage.getMessages(sessionId)) {
      byId[message.id] = message;
    }
    for (final message in _messages.where((m) => m.sessionId == sessionId)) {
      byId[message.id] = message;
    }
    final messages = byId.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  Future<void> markSessionRead(String sessionId) async {
    await _storage.markSessionRead(sessionId);
    _loadSessions();
  }

  Future<void> addSession(
    String openId, {
    required bool isGroup,
    String name = '',
  }) async {
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
    if (_disposed) return;
    _loadSessions();
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
    _messages.clear();
    _lastInboundMessageIds.clear();
    _replySequences.clear();
    _replyEvents.clear();
    _acknowledgedInteractions.clear();
    _autoDispatchedMessageIds.clear();
    _fullGroupMessageCount = 0;
    _loadConfig();
    _loadSessions();
  }

  @override
  void dispose() {
    _disposed = true;
    _tokenRefreshTimer?.cancel();
    _wsService.dispose();
    super.dispose();
  }
}
