import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

enum QrLoginPhase {
  idle,
  creating,
  waiting,
  pending,
  authorized,
  saved,
  expired,
  failed,
  cancelled,
}

class QrBotCredentials {
  final String appId;
  final String appSecret;
  const QrBotCredentials(this.appId, this.appSecret);

  @override
  String toString() => 'QrBotCredentials(<redacted>)';
}

/// Independent Dart protocol adapter for Tencent's QR binding service.
/// Wire format checked against @tencent-connect/qqbot-connector 1.2.0.
/// https://www.npmjs.com/package/@tencent-connect/qqbot-connector
/// No Node runtime, third-party relay/QR image server or personal-QQ protocol.
class QqQrLoginService extends ChangeNotifier {
  final Dio _http;
  final bool _ownsHttp;
  final Duration pollInterval;
  final Duration lifetime;
  final AesGcm _cipher = AesGcm.with256bits();
  SecretKeyData? _key;
  CancelToken? _cancel;
  Timer? _pollTimer, _expiryTimer;
  String? _task;
  int _generation = 0, _failures = 0;
  bool _disposed = false, _foreground = true, _polling = false;
  DateTime? _expiresAt;

  QrLoginPhase phase = QrLoginPhase.idle;
  String message = '使用手机 QQ 扫码，在腾讯官方页面确认机器人授权。';
  Uri? qrUri;
  QrBotCredentials? credentials;

  QqQrLoginService({
    Dio? http,
    this.pollInterval = const Duration(seconds: 2),
    this.lifetime = const Duration(minutes: 5),
  }) : _ownsHttp = http == null,
       _http =
           http ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               sendTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 10),
               followRedirects: false,
             ),
           );

  bool get active => const {
    QrLoginPhase.creating,
    QrLoginPhase.waiting,
    QrLoginPhase.pending,
  }.contains(phase);

  bool _current(int generation) => !_disposed && generation == _generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<Map<String, dynamic>> _request(
    String endpoint,
    Map<String, String> body,
  ) async {
    // The origin is fixed; neither task data nor custom API settings can redirect it.
    final response = await _http.postUri<ResponseBody>(
      Uri.https('q.qq.com', '/lite/$endpoint'),
      data: body,
      cancelToken: _cancel,
      options: Options(
        contentType: Headers.jsonContentType,
        headers: const {'Accept': 'application/json'},
        responseType: ResponseType.stream,
        followRedirects: false,
        validateStatus: (status) => status == 200,
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ),
    );
    final data = BytesBuilder(copy: false);
    if (response.data == null) throw const FormatException('Empty response');
    await for (final chunk in response.data!.stream.timeout(
      const Duration(seconds: 10),
    )) {
      if (data.length + chunk.length > 65536) {
        throw const FormatException('Oversized response');
      }
      data.add(chunk);
    }
    final envelope = jsonDecode(utf8.decode(data.takeBytes()));
    if (envelope is! Map ||
        envelope['retcode'] != 0 ||
        envelope['data'] is! Map) {
      throw const FormatException('Binding service rejected the request');
    }
    return Map<String, dynamic>.from(envelope['data'] as Map);
  }

  Future<void> start() async {
    if (_disposed) return;
    _clear();
    final generation = ++_generation;
    _cancel = CancelToken();
    _failures = 0;
    _polling = false;
    phase = QrLoginPhase.creating;
    message = '正在向腾讯获取授权二维码…';
    _notify();
    try {
      final random = Random.secure();
      _key = SecretKeyData(
        Uint8List.fromList(List.generate(32, (_) => random.nextInt(256))),
        overwriteWhenDestroyed: true,
      );
      final encodedKey = base64Encode(_key!.bytes);
      final data = await _request('create_bind_task', {'key': encodedKey});
      if (!_current(generation)) return;
      final task = data['task_id'];
      if (task is! String ||
          task.isEmpty ||
          task.length > 512 ||
          RegExp(r'[\x00-\x20\x7f]').hasMatch(task)) {
        throw const FormatException('Invalid task');
      }
      _task = task;
      qrUri = Uri.https('q.qq.com', '/qqbot/openclaw/connect.html', {
        'task_id': task,
        'source': '',
        '_wv': '2',
      });
      _expiresAt = DateTime.now().add(lifetime);
      _expiryTimer = Timer(lifetime, _expire);
      phase = QrLoginPhase.waiting;
      message = '请使用手机 QQ 扫码，并在官方页面确认。';
      _notify();
      if (_foreground) unawaited(_poll(generation));
    } catch (_) {
      if (!_current(generation)) return;
      _fail('无法获取二维码，请检查网络或改用手动配置。');
    }
  }

  Future<void> _poll(int generation) async {
    if (!_current(generation) ||
        !_foreground ||
        _polling ||
        !active ||
        _task == null) {
      return;
    }
    if (_expired) {
      _expire();
      return;
    }
    _polling = true;
    try {
      final data = await _request('poll_bind_result', {'task_id': _task!});
      if (!_current(generation) || !active) return;
      if (_expired) {
        _expire();
        return;
      }
      _failures = 0;
      switch (data['status']) {
        case 0:
          phase = QrLoginPhase.waiting;
          message = '等待手机 QQ 扫码…';
        case 1:
          phase = QrLoginPhase.pending;
          // PENDING is also returned immediately after creation: it is not
          // proof that somebody has scanned the QR code.
          message = '请使用手机 QQ 扫码，并在官方页面确认机器人授权。';
        case 2:
          final appId = data['bot_appid']?.toString() ?? '';
          final encrypted = data['bot_encrypt_secret'];
          if (!RegExp(r'^\d{1,32}$').hasMatch(appId) ||
              encrypted is! String ||
              encrypted.length > 16384) {
            throw const FormatException('Invalid credentials');
          }
          final packed = base64Decode(encrypted);
          if (packed.length < 29) {
            throw const FormatException('Invalid ciphertext');
          }
          final plain = await _cipher.decrypt(
            SecretBox(
              packed.sublist(12, packed.length - 16),
              nonce: packed.sublist(0, 12),
              mac: Mac(packed.sublist(packed.length - 16)),
            ),
            secretKey: _key!,
          );
          if (!_current(generation) || !active) return;
          if (_expired) {
            _expire();
            return;
          }
          final secret = utf8.decode(plain);
          if (secret.isEmpty ||
              secret.length > 4096 ||
              RegExp(r'[\x00-\x20\x7f]').hasMatch(secret)) {
            throw const FormatException('Invalid secret');
          }
          _clearTransport();
          qrUri = null;
          credentials = QrBotCredentials(appId, secret);
          phase = QrLoginPhase.authorized;
          message = '授权成功，正在自动保存新密钥并连接机器人。';
        case 3:
          _expire();
          return;
        default:
          throw const FormatException('Unknown binding status');
      }
      _notify();
    } on SecretBoxAuthenticationError {
      if (_current(generation)) _fail('授权结果校验失败，请重新生成二维码。');
    } on FormatException {
      if (_current(generation)) _fail('授权响应无效，请重新生成二维码或使用手动配置。');
    } catch (_) {
      if (!_current(generation) || !active) return;
      _failures++;
      if (_failures >= 3) {
        _fail('暂时无法查询扫码结果，请检查网络后重新生成二维码。');
      } else {
        message = '暂时无法查询扫码结果，正在重试（$_failures/3）…';
        _notify();
      }
    } finally {
      if (_current(generation)) {
        _polling = false;
        if (active && _foreground) {
          _pollTimer = Timer(pollInterval, () => unawaited(_poll(generation)));
        }
      }
    }
  }

  bool get _expired =>
      _expiresAt != null && !DateTime.now().isBefore(_expiresAt!);

  /// Backgrounding never starts a second poll; resume checks the wall-clock expiry.
  void setForeground(bool foreground) {
    if (_disposed) return;
    _foreground = foreground;
    _pollTimer?.cancel();
    if (!active) return;
    if (_expired) {
      _expire();
      return;
    }
    if (foreground && !_polling && _task != null) unawaited(_poll(_generation));
  }

  void _expire() {
    if (_disposed || !active) return;
    _generation++;
    _clear();
    phase = QrLoginPhase.expired;
    message = '二维码已过期，请重新生成。';
    _notify();
  }

  void _fail(String reason) {
    _generation++;
    _clear();
    phase = QrLoginPhase.failed;
    message = reason;
    _notify();
  }

  void markSaved() {
    if (_disposed) return;
    _generation++;
    _clear();
    phase = QrLoginPhase.saved;
    message = '机器人凭据已保存，连接状态以工作台为准。';
    _notify();
  }

  void cancel() {
    if (_disposed) return;
    _generation++;
    _clear();
    phase = QrLoginPhase.cancelled;
    message = '已停止本机等待；不会保存本次凭据。';
    _notify();
  }

  void _clearTransport() {
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    _cancel?.cancel();
    _cancel = null;
    _key?.destroy();
    _key = null;
    _task = null;
    _expiresAt = null;
  }

  void _clear() {
    _clearTransport();
    credentials = null;
    qrUri = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _clear();
    if (_ownsHttp) _http.close(force: true);
    super.dispose();
  }
}
