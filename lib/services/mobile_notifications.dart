import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bot_client.dart';
import '../models/group_notice.dart';
import '../models/message.dart';
import '../utils/platforms.dart';
import 'storage_service.dart';

/// Local OS notifications only. No push token, server upload, or background
/// execution promise: the app must actually receive the QQ gateway event.
class MobileNotifications extends ChangeNotifier with WidgetsBindingObserver {
  static const channel = MethodChannel('cn.uuze.botmanager/notifications');
  final BotClient bot;
  final StorageService storage;
  final String? Function() visibleSession;
  final Future<void> Function(String appId, String sessionId, String noticeId)
  onOpen;
  final bool supported;
  bool enabled = false, permitted = false, busy = false, inboxVisible = false;
  String error = '';
  bool _disposed = false;
  int _epoch = -1;
  StreamSubscription<MessageModel>? _messages;
  StreamSubscription<GroupNotice>? _events;
  Timer? _permissionTimer;
  Completer<bool>? _permissionCheck;
  String? _lastOpened;
  DateTime? _lastOpenedAt;
  MobileNotifications({
    required this.bot,
    required this.storage,
    required this.visibleSession,
    required this.onOpen,
    bool? supported,
  }) : supported = supported ?? isMobilePlatform;

  Future<void> start() async {
    if (!supported || _disposed) return;
    enabled = storage.getSystemNotificationsEnabled();
    _epoch = bot.accountEpoch;
    WidgetsBinding.instance.addObserver(this);
    bot.addListener(_changedBot);
    _messages = bot.incomingNotices.listen(
      (message) => unawaited(_message(message)),
    );
    _events = bot.groups.events.listen((notice) => unawaited(_event(notice)));
    channel.setMethodCallHandler((call) async {
      if (call.method == 'opened') {
        try {
          await channel.invokeMethod<String>('consumeLaunch');
        } catch (_) {}
        await _open(call.arguments);
      }
    });
    await refreshPermission();
    if (_disposed) return;
    try {
      final payload = await channel.invokeMethod<String>('consumeLaunch');
      if (!_disposed && payload != null) await _open(payload);
    } catch (_) {
      /* The workbench still works if a native channel is absent. */
    }
  }

  void _changedBot() {
    if (_epoch == bot.accountEpoch) return;
    _epoch = bot.accountEpoch;
    unawaited(_cancelAll());
  }

  Future<void> refreshPermission() async {
    if (!supported || _disposed) return;
    if (_permissionCheck != null) return;
    final check = Completer<bool>();
    _permissionCheck = check;
    _permissionTimer = Timer(const Duration(seconds: 4), () {
      if (!check.isCompleted) check.complete(false);
    });
    try {
      unawaited(
        channel
            .invokeMethod<bool>('isAllowed')
            .then(
              (value) {
                if (!check.isCompleted) check.complete(value ?? false);
              },
              onError: (Object _) {
                if (!check.isCompleted) check.complete(false);
              },
            ),
      );
      final allowed = await check.future;
      if (!_disposed) {
        permitted = allowed;
        notifyListeners();
      }
    } finally {
      _permissionTimer?.cancel();
      _permissionTimer = null;
      _permissionCheck = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refreshPermission());
  }

  Future<void> setEnabled(bool value) async {
    if (!supported || busy) return;
    busy = true;
    error = '';
    notifyListeners();
    try {
      if (value) {
        permitted =
            await channel.invokeMethod<bool>('requestPermission') ?? false;
      }
      if (value && !permitted) throw StateError('系统未允许通知，请在系统的应用通知设置中开启后重试');
      await storage.setSystemNotificationsEnabled(value);
      enabled = value;
      if (!value) await _cancelAll();
    } catch (failure) {
      error = failure is StateError
          ? failure.message.toString()
          : '系统通知暂不可用，聊天和群事件仍可在应用内查看';
      rethrow;
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> openSettings() async {
    if (supported) await channel.invokeMethod<void>('openSettings');
  }

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  Future<void> _message(MessageModel message) async {
    if (message.extra?['botAppId'] != bot.config.appId ||
        message.isBotAuthor ||
        (_foreground && visibleSession() == message.sessionId)) {
      return;
    }
    final session = bot.sessions
        .where((s) => s.id == message.sessionId)
        .firstOrNull;
    if (session == null || session.isMuted) return;
    await _show(
      message.sessionId,
      session.name,
      session.sessionType == 1
          ? '${message.senderName}：${message.sessionPreview}'
          : message.sessionPreview,
    );
  }

  Future<void> _event(GroupNotice notice) async {
    if (notice.appId != bot.config.appId ||
        (_foreground && inboxVisible) ||
        bot.sessions.any((s) => s.id == notice.groupId && s.isMuted)) {
      return;
    }
    await _show(
      notice.groupId,
      notice.title,
      '${notice.username} · ${notice.statusLabel}',
      noticeId: notice.id,
    );
  }

  Future<void> _show(
    String sessionId,
    String title,
    String body, {
    String noticeId = '',
  }) async {
    if (_disposed || !supported || !enabled || !permitted) return;
    try {
      await channel.invokeMethod<void>('show', {
        'id': notificationId(
          '${bot.config.appId}:$sessionId:${noticeId.isEmpty ? 'chat' : 'events'}',
        ),
        'title': title.characters.take(100).toString(),
        'body': body.characters.take(240).toString(),
        'payload': jsonEncode({
          'appId': bot.config.appId,
          'sessionId': sessionId,
          'noticeId': noticeId,
        }),
        'thread': '${bot.config.appId}:$sessionId',
      });
    } catch (_) {
      error = '系统通知发送失败，可在应用内查看消息与通知';
      if (!_disposed) notifyListeners();
    }
  }

  static int notificationId(String value) {
    var hash = 2166136261;
    for (final byte in utf8.encode(value)) {
      hash = ((hash ^ byte) * 16777619) & 0x7fffffff;
    }
    return hash;
  }

  Future<void> _open(dynamic raw) async {
    if (_disposed || raw is! String || raw.length > 8192) return;
    final now = DateTime.now();
    if (_lastOpened == raw &&
        _lastOpenedAt != null &&
        now.difference(_lastOpenedAt!) < const Duration(seconds: 2)) {
      return;
    }
    try {
      final map = jsonDecode(raw);
      if (map is! Map ||
          map['appId'] is! String ||
          map['sessionId'] is! String ||
          map['noticeId'] is! String ||
          !bot.botProfiles.any((p) => p.appId == map['appId'])) {
        return;
      }
      _lastOpened = raw;
      _lastOpenedAt = now;
      await onOpen(map['appId'], map['sessionId'], map['noticeId']);
    } catch (_) {
      /* Old or malformed pending-intent payloads are ignored. */
    }
  }

  Future<void> _cancelAll() async {
    try {
      await channel.invokeMethod<void>('cancelAll');
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _permissionTimer?.cancel();
    if (_permissionCheck?.isCompleted == false) {
      _permissionCheck!.complete(false);
    }
    if (supported) {
      WidgetsBinding.instance.removeObserver(this);
      bot.removeListener(_changedBot);
      channel.setMethodCallHandler(null);
      unawaited(_messages?.cancel());
      unawaited(_events?.cancel());
    }
    super.dispose();
  }
}
