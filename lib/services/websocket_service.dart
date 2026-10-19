import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:logging/logging.dart';
import '../utils/helpers.dart';
import '../utils/profile_helpers.dart';
import '../models/received_message.dart';

enum ConnectionState { disconnected, connecting, connected, reconnecting }

class WebSocketService {
  final Logger _log = Logger('WebSocketService');
  WebSocketChannel? _channel;
  ConnectionState _state = ConnectionState.disconnected;
  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  StreamSubscription<dynamic>? _subscription;
  Completer<bool>? _authentication;
  int _heartbeatInterval = 45000;
  int? _lastSequence;
  String? _sessionId;
  String _lastError = '';
  int _generation = 0;
  bool _allowReconnect = false;
  bool _heartbeatAcknowledged = true;
  bool _disposed = false;

  String? _wsUrl;
  String? _accessToken;
  bool _autoReconnect = true;
  Duration _reconnectInterval = const Duration(seconds: 5);
  Function(String?)? onConnectionStateChanged;
  Function(Map<String, dynamic> readyData)? onReady;
  Function(String eventType, Map<String, dynamic> eventData)? onDispatch;
  Function(int heartbeatIntervalMs)? onHello;
  Function()? onHeartbeatAck;
  Future<String?> Function()? refreshAccessToken;

  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;
  int get transportGeneration => _generation;
  ConnectionState get state => _state;
  String get lastError => _lastError;

  void updateAccessToken(String token) => _accessToken = token;

  void _setState(ConnectionState newState) {
    _state = newState;
    onConnectionStateChanged?.call(_stateLabel);
  }

  String get _stateLabel {
    switch (_state) {
      case ConnectionState.disconnected:
        return '离线';
      case ConnectionState.connecting:
        return '连接中...';
      case ConnectionState.connected:
        return '在线';
      case ConnectionState.reconnecting:
        return '重连中...';
    }
  }

  bool get isConnected => _state == ConnectionState.connected;

  /// Connect to QQ Bot WebSocket using the access_token.
  Future<bool> connect({
    required String wsUrl,
    required String accessToken,
    bool autoReconnect = true,
    Duration reconnectInterval = const Duration(seconds: 5),
  }) async {
    _wsUrl = wsUrl;
    _accessToken = accessToken;
    _autoReconnect = autoReconnect;
    _allowReconnect = true;
    _reconnectInterval = reconnectInterval;
    _reconnectTimer?.cancel();
    _sessionId = null;
    _lastSequence = null;
    return _openSocket();
  }

  Future<bool> _openSocket({bool reconnecting = false}) async {
    _closeTransport();
    if (_disposed) return false;
    final generation = _generation;
    _lastError = '';
    final authentication = Completer<bool>();
    _authentication = authentication;
    try {
      _setState(
        reconnecting
            ? ConnectionState.reconnecting
            : ConnectionState.connecting,
      );
      if (reconnecting && refreshAccessToken != null) {
        final token = await refreshAccessToken!();
        if (generation != _generation) return false;
        if (token == null || token.isEmpty) throw StateError('重新连接前刷新访问凭证失败');
        _accessToken = token;
      }
      final channel = WebSocketChannel.connect(Uri.parse(_wsUrl!));
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 15));
      if (generation != _generation || _disposed) return false;
      _listenToMessages(channel, generation);
      return await authentication.future.timeout(const Duration(seconds: 15));
    } catch (e) {
      if (generation == _generation && !_disposed) {
        _handleDisconnect(scheduleReconnect: true, error: '网关连接或鉴权失败: $e');
      }
      return false;
    }
  }

  void _listenToMessages(WebSocketChannel channel, int generation) {
    _subscription = channel.stream.listen(
      (data) {
        if (generation != _generation || _disposed) return;
        try {
          final text = data is String ? data : utf8.decode(data as List<int>);
          final message = jsonDecode(text) as Map<String, dynamic>;
          _handleMessage(message);
        } catch (e) {
          _log.warning('网关消息解析失败: $e');
        }
      },
      onError: (error) {
        if (generation != _generation || _disposed) return;
        _handleDisconnect(scheduleReconnect: true, error: '网关连接错误: $error');
      },
      onDone: () {
        if (generation != _generation || _disposed) return;
        _handleDisconnect(
          scheduleReconnect: true,
          error:
              '网关已关闭连接（${channel.closeCode ?? '-'}）${channel.closeReason ?? ''}',
        );
      },
    );
  }

  void _handleMessage(Map<String, dynamic> message) {
    final opCode = message['op'] as int?;
    final seq = message['s'] as int?;
    if (seq != null) _lastSequence = seq;

    switch (opCode) {
      case 0: // Dispatch
        final eventType = message['t'] as String?;
        final eventData = message['d'] is Map
            ? Map<String, dynamic>.from(message['d'])
            : <String, dynamic>{};
        if (eventType != null) {
          onDispatch?.call(eventType, {
            ...eventData,
            '_eventId': message['id']?.toString() ?? '',
          });
        }

        switch (eventType) {
          case String type when _isRecallEvent(type):
            _messageController.add({
              ..._parseRecallEvent(eventData, type),
              '_transportGeneration': _generation,
            });
            break;
          case 'C2C_MESSAGE_CREATE': // Friend message
          case 'GROUP_AT_MESSAGE_CREATE': // Group @message
          case 'GROUP_MESSAGE_CREATE':
            _messageController.add({
              ..._parseMessageEvent(
                eventData,
                eventType,
                message['id']?.toString(),
              ),
              '_transportGeneration': _generation,
            });
            break;
          case 'READY':
            _sessionId = eventData['session_id']?.toString();
            _setState(ConnectionState.connected);
            if (_authentication?.isCompleted == false) {
              _authentication!.complete(true);
            }
            onReady?.call(eventData);
            break;
          case 'RESUMED':
            _setState(ConnectionState.connected);
            if (_authentication?.isCompleted == false) {
              _authentication!.complete(true);
            }
            _log.info('网关会话已恢复');
            break;
        }
        break;

      case 1: // Heartbeat (server asks us to respond)
        _sendHeartbeat(checkAck: false);
        break;

      case 7: // Reconnect
        _handleDisconnect(scheduleReconnect: true, error: '服务器要求重新连接');
        break;

      case 9: // Invalid session
        _sessionId = null;
        _lastSequence = null;
        _handleDisconnect(scheduleReconnect: true, error: '网关会话已失效，正在重新鉴权');
        break;

      case 10: // Hello
        final interval = message['d']?['heartbeat_interval'] as int?;
        if (interval != null) {
          _heartbeatInterval = interval > 0 ? interval : 45000;
          onHello?.call(interval);
        }
        _startHeartbeat();
        if (_sessionId != null && _lastSequence != null) {
          _send({
            'op': 6,
            'd': {
              'token': 'QQBot $_accessToken',
              'session_id': _sessionId,
              'seq': _lastSequence,
            },
          });
        } else {
          _identify();
        }
        break;

      case 11: // Heartbeat ACK
        _heartbeatAcknowledged = true;
        onHeartbeatAck?.call();
        break;
    }
  }

  Map<String, dynamic> _parseMessageEvent(
    Map<String, dynamic> data,
    String? eventType,
    String? eventId,
  ) {
    final author = data['author'] as Map<String, dynamic>? ?? {};
    final groupId =
        data['group_openid']?.toString() ?? data['group_id']?.toString();
    final isGroup = groupId != null && groupId.isNotEmpty;
    final userOpenId =
        data['openid']?.toString() ??
        data['user_openid']?.toString() ??
        data['member_openid']?.toString() ??
        (isGroup ? author['member_openid'] : author['user_openid'])
            ?.toString() ??
        author['member_openid']?.toString() ??
        author['id']?.toString();
    final senderName = firstProfileName([
      author['username'],
      author['nick'],
      author['nickname'],
      author['name'],
      data['username'],
      data['nick'],
      data['nickname'],
      data['member_name'],
      data['member_nick'],
    ]);
    final displayName = senderName.isNotEmpty
        ? senderName
        : _openIdLabel(userOpenId);
    final senderRole = isGroup ? author['member_role']?.toString() ?? '' : '';
    final rawContent = data['content']?.toString() ?? '';
    final received = ReceivedMessageBody.fromMap(data);
    final displayContent = formatQqMessageContent(
      rawContent,
      mentions: data['mentions'] as List?,
    );

    return {
      'id': data['id']?.toString() ?? '',
      'eventId': eventId ?? data['event_id']?.toString() ?? '',
      'eventType': eventType ?? '',
      'sessionId': groupId ?? userOpenId ?? '',
      'senderId': userOpenId ?? '',
      'senderName': displayName,
      'senderNameIsFallback': senderName.isEmpty,
      'senderAvatarUrl': firstProfileAvatar([
        author['avatar'],
        author['avatar_url'],
      ]),
      'groupName': firstProfileName([
        data['group_name'],
        data['group'] is Map
            ? data['group']['group_name'] ?? data['group']['name']
            : null,
      ]),
      'groupAvatarUrl': firstProfileAvatar([
        data['group_avatar'],
        data['group_avatar_url'],
        data['group'] is Map
            ? data['group']['avatar'] ?? data['group']['avatar_url']
            : null,
      ]),
      'senderLevel': '',
      'senderTitle': '',
      'senderRole': senderRole,
      'senderIsBot': author['bot'] == true,
      'sourceMessageType': received.type,
      'content': displayContent,
      'rawContent': rawContent,
      'messageType': data['markdown'] is Map
          ? 2
          : (_extractImageUrl(data) != null ? 7 : 0),
      'timestamp': _parseEventTime(data['timestamp']),
      'isGroup': isGroup,
      'mentions': data['mentions'] is List ? data['mentions'] : const [],
      'imageUrl': _extractImageUrl(data),
      'markdownContent': data['markdown']?['content']?.toString(),
      'extra': data,
    };
  }

  String _openIdLabel(String? id) {
    final value = id ?? '';
    if (value.isEmpty) return '用户';
    if (value.length <= 12) return value;
    return '${value.substring(0, 6)}...${value.substring(value.length - 4)}';
  }

  bool _isRecallEvent(String eventType) {
    final upper = eventType.toUpperCase();
    return upper.contains('RECALL') ||
        upper.contains('REVOKE') ||
        (upper.contains('MESSAGE') && upper.contains('DELETE'));
  }

  Map<String, dynamic> _parseRecallEvent(
    Map<String, dynamic> data,
    String eventType,
  ) {
    final author = data['author'] as Map<String, dynamic>? ?? {};
    final groupId =
        data['group_openid']?.toString() ?? data['group_id']?.toString();
    final userOpenId =
        data['openid']?.toString() ??
        data['user_openid']?.toString() ??
        data['member_openid']?.toString() ??
        data['op_member_openid']?.toString() ??
        author['member_openid']?.toString() ??
        author['user_openid']?.toString() ??
        author['id']?.toString();
    return {
      'isRecallEvent': true,
      'id':
          data['id']?.toString() ??
          data['message_id']?.toString() ??
          data['msg_id']?.toString() ??
          data['messageId']?.toString() ??
          '',
      'sessionId': groupId ?? userOpenId ?? '',
      'senderId': userOpenId ?? '',
      'senderName': author['username']?.toString() ?? userOpenId ?? '用户',
      'eventType': eventType,
      'timestamp': _parseEventTime(data['timestamp']),
      'extra': data,
    };
  }

  DateTime _parseEventTime(dynamic value) {
    if (value is int) {
      final milliseconds = value > 1000000000000 ? value : value * 1000;
      return DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    }
    return (DateTime.tryParse(value?.toString() ?? '') ?? DateTime.now())
        .toLocal();
  }

  String? _extractImageUrl(Map<String, dynamic> data) {
    final attachments = data['attachments'];
    if (attachments is List) {
      for (final attachment in attachments) {
        if (attachment is! Map) continue;
        final type = attachment['content_type']?.toString() ?? '';
        if (type.isNotEmpty && !type.startsWith('image/')) continue;
        final url =
            attachment['url']?.toString() ??
            attachment['image_url']?.toString() ??
            attachment['cdn_url']?.toString();
        if (url != null && url.isNotEmpty) {
          return url.startsWith('//') ? 'https:$url' : url;
        }
      }
    }
    final media = data['media'];
    if (media is Map) {
      return media['url']?.toString() ??
          media['image_url']?.toString() ??
          media['cdn_url']?.toString();
    }
    return null;
  }

  void _identify() {
    if (_channel != null && _accessToken != null) {
      final payload = {
        'op': 2,
        'd': {
          'token': 'QQBot $_accessToken',
          'intents': (1 << 24) | (1 << 25) | (1 << 26),
          'shard': [0, 1],
          'properties': {r'$os': 'desktop', r'$device': 'qq-bot-manager'},
        },
      };
      _send(payload);
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatAcknowledged = true;
    _heartbeatTimer = Timer.periodic(
      Duration(milliseconds: _heartbeatInterval),
      (_) => _sendHeartbeat(),
    );
  }

  void _sendHeartbeat({bool checkAck = true}) {
    if (_channel == null) return;
    if (checkAck && !_heartbeatAcknowledged) {
      _handleDisconnect(scheduleReconnect: true, error: '网关心跳超时，正在重新连接');
      return;
    }
    _heartbeatAcknowledged = false;
    _send({'op': 1, 'd': _lastSequence});
  }

  void _handleDisconnect({bool scheduleReconnect = false, String? error}) {
    if (error != null) {
      _lastError = error;
      _log.warning(error);
    }
    _closeTransport();
    _setState(ConnectionState.disconnected);
    if (scheduleReconnect) _scheduleReconnect();
  }

  void _closeTransport() {
    _generation++;
    _heartbeatTimer?.cancel();
    if (_authentication?.isCompleted == false) _authentication!.complete(false);
    _authentication = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    final channel = _channel;
    _channel = null;
    if (channel != null) unawaited(channel.sink.close());
  }

  void _scheduleReconnect() {
    if (!_autoReconnect || !_allowReconnect || _disposed) return;
    _reconnectTimer?.cancel();
    _setState(ConnectionState.reconnecting);
    _reconnectTimer = Timer(_reconnectInterval, () {
      if (_wsUrl != null && _accessToken != null) {
        unawaited(_openSocket(reconnecting: true));
      }
    });
  }

  void _send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (e) {
      _log.warning('Failed to send: $e');
    }
  }

  void disconnect() {
    _allowReconnect = false;
    _reconnectTimer?.cancel();
    _closeTransport();
    _sessionId = null;
    _lastSequence = null;
    _setState(ConnectionState.disconnected);
    _log.info('网关连接已断开');
  }

  void dispose() {
    _disposed = true;
    disconnect();
    _messageController.close();
  }
}
