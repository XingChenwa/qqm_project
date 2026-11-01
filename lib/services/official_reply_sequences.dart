import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'shared_qq_gateway.dart';

/// Protocol bookkeeping only. Chat messages, prompts and plugin state remain
/// in their own workspaces. Allocation is synchronous to avoid an async race.
class OfficialReplySequences {
  final int Function(String key)? read;
  final Future<void> Function(String key, int value)? write;
  final _values = <String, int>{};
  Future<void> _pending = Future.value();
  bool _writeFailed = false;
  OfficialReplySequences({this.read, this.write});

  static String scope(String appId, String apiBase) =>
      officialQqScope(appId, apiBase);
  String _key(String scope, String reference) =>
      sha256.convert(utf8.encode(jsonEncode([scope, reference]))).toString();
  int used(String scope, String reference, {int floor = 0}) {
    final key = _key(scope, reference);
    final local = _values[key] ?? 0, persisted = read?.call(key) ?? 0;
    return [floor, local, persisted].reduce((a, b) => a > b ? a : b);
  }

  int reserve(String scope, String reference, {int minimum = 1, int? limit}) {
    final key = _key(scope, reference), next = used(scope, reference) + 1;
    final value = minimum > next ? minimum : next;
    if (limit != null && value > limit) {
      throw const FormatException('这条消息的被动回复次数已用完，请等待新消息。');
    }
    _values[key] = value;
    if (_values.length > 8192) _values.remove(_values.keys.first);
    if (write != null) {
      _pending = _pending.then((_) async {
        try {
          await write!(key, value);
        } catch (_) {
          _writeFailed = true;
        }
      });
    }
    return value;
  }

  Future<void> settled() async {
    await _pending;
    if (_writeFailed) {
      throw const FormatException('回复序号未能保存，请检查存储权限后重启；本次消息未发送。');
    }
  }
}
