import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/bot_client.dart';
import 'storage_service.dart';

/// A user-visible Android foreground service is optional. iOS is deliberately
/// not advertised as always-on; both platforms validate the gateway on resume.
class MobileConnection extends ChangeNotifier with WidgetsBindingObserver {
  static const channel = MethodChannel('cn.uuze.botmanager/background');
  final BotClient bot;
  final StorageService storage;
  bool enabled = false, running = false, busy = false;
  String error = '';
  bool _disposed = false, _started = false, _syncing = false;

  MobileConnection({required this.bot, required this.storage});
  bool get android => defaultTargetPlatform == TargetPlatform.android;
  bool get ios => defaultTargetPlatform == TargetPlatform.iOS;
  bool get supported => !kIsWeb && (android || ios);

  void start() {
    if (!supported || _started) return;
    _started = true;
    enabled = storage.getBackgroundConnectionEnabled();
    WidgetsBinding.instance.addObserver(this);
    bot.addListener(_changedBot);
    unawaited(_sync());
  }

  void _changedBot() {
    unawaited(_sync());
  }

  Future<void> _sync() async {
    if (_disposed || !android || _syncing) return;
    final wanted = enabled && bot.connectionRequested;
    if (wanted == running) return;
    // Android 12+ requires starting from a user-visible state. Wait for resume
    // instead of repeatedly trying to start a foreground service in background.
    if (wanted &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _syncing = true;
    try {
      if (wanted) {
        await channel
            .invokeMethod<void>('start')
            .timeout(const Duration(seconds: 4));
        if (_disposed) {
          await channel.invokeMethod<void>('stop');
          return;
        }
        running = true;
      } else {
        await channel
            .invokeMethod<void>('stop')
            .timeout(const Duration(seconds: 4));
        running = false;
      }
      error = '';
    } catch (_) {
      running = false;
      error = '后台保活尚未启动，请回到应用，检查通知权限及系统电池限制后重试。';
    } finally {
      _syncing = false;
      if (!_disposed) notifyListeners();
      if (!_disposed &&
          error.isEmpty &&
          (enabled && bot.connectionRequested) != running) {
        unawaited(_sync());
      }
    }
  }

  Future<void> setEnabled(bool value) async {
    if (!android || busy || _disposed) return;
    busy = true;
    error = '';
    notifyListeners();
    try {
      if (value &&
          await const MethodChannel(
                'cn.uuze.botmanager/notifications',
              ).invokeMethod<bool>('requestPermission') !=
              true) {
        error = '请先允许应用通知，再开启后台连接。';
        throw StateError(error);
      }
      await storage.setBackgroundConnectionEnabled(value);
      enabled = value;
      await _sync();
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> openSettings({bool battery = false}) async {
    await channel.invokeMethod<void>(
      battery && android ? 'batterySettings' : 'openSettings',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(bot.recoverAfterResume());
      unawaited(_sync());
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      bot.removeListener(_changedBot);
    }
    if (running) {
      unawaited(channel.invokeMethod<void>('stop').catchError((Object _) {}));
    }
    super.dispose();
  }
}
