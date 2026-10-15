import 'dart:async';
import 'dart:collection';

import 'api_service.dart';

/// Group and member lookups each have a 30 QPM limit. A shared queue is more
/// conservative: requests start at least 2.1s apart, and do not block messaging.
class ProfileRequestQueue {
  final Duration spacing;
  final _waiting = Queue<_ProfileRequest>();
  final _inFlight = <String, Future<ApiResult<Map<String, dynamic>>>>{};
  final _denied = <String>{};
  Timer? _timer;
  DateTime? _lastStarted;
  bool _busy = false;
  bool _disposed = false;

  ProfileRequestQueue({this.spacing = const Duration(milliseconds: 2100)});

  bool isDenied(String kind) => _denied.contains(kind);

  Future<ApiResult<Map<String, dynamic>>> request({
    required String kind,
    required String key,
    required Future<ApiResult<Map<String, dynamic>>> Function() load,
    bool force = false,
  }) {
    final identity = '$kind:$key';
    final existing = _inFlight[identity];
    if (existing != null) return existing;
    if (_disposed) return Future.value(ApiResult.failure('资料请求已取消'));
    if (force) _denied.remove(kind);
    if (_denied.contains(kind)) {
      return Future.value(ApiResult.failure('平台未开放资料查询权限', errorCode: 11253));
    }
    if (_waiting.length >= 32) {
      return Future.value(ApiResult.failure('资料查询队列繁忙，请稍后打开会话重试'));
    }
    final pending = _ProfileRequest(kind, load);
    final future = pending.completer.future.whenComplete(() {
      _inFlight.remove(identity);
    });
    _inFlight[identity] = future;
    _waiting.add(pending);
    _pump();
    return future;
  }

  void _pump() {
    if (_disposed || _busy || _timer != null || _waiting.isEmpty) return;
    final remaining = _lastStarted == null
        ? Duration.zero
        : spacing - DateTime.now().difference(_lastStarted!);
    if (remaining > Duration.zero) {
      _timer = Timer(remaining, () {
        _timer = null;
        _pump();
      });
      return;
    }
    final pending = _waiting.removeFirst();
    if (_denied.contains(pending.kind)) {
      pending.completer.complete(
        ApiResult.failure('平台未开放资料查询权限', errorCode: 11253),
      );
      _pump();
      return;
    }
    _busy = true;
    _lastStarted = DateTime.now();
    _run(pending);
  }

  Future<void> _run(_ProfileRequest pending) async {
    try {
      final result = await pending.load();
      if (result.errorCode == 11253 || result.statusCode == 403) {
        _denied.add(pending.kind);
      }
      pending.completer.complete(result);
    } catch (_) {
      pending.completer.complete(ApiResult.failure('资料查询失败，请稍后重试'));
    } finally {
      _busy = false;
      _pump();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final pending in _waiting) {
      pending.completer.complete(ApiResult.failure('资料请求已取消'));
    }
    _waiting.clear();
  }
}

class _ProfileRequest {
  final String kind;
  final Future<ApiResult<Map<String, dynamic>>> Function() load;
  final completer = Completer<ApiResult<Map<String, dynamic>>>();
  _ProfileRequest(this.kind, this.load);
}
