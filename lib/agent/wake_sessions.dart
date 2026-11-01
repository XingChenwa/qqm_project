import 'dart:async';

/// Group wake state is transient and scoped to a connection + chat. Only the
/// controller's accepted human messages refresh it, never a model response.
class AgentWakeSessions {
  static const idleTimeout = Duration(minutes: 5);
  final DateTime Function() _clock;
  final void Function(String connectionId, String sessionKey)? onSleep;
  final _entries = <String, _AwakeSession>{};
  AgentWakeSessions({DateTime Function()? clock, this.onSleep})
    : _clock = clock ?? DateTime.now;

  bool isAwake(String key) => _entries[key]?.until.isAfter(_clock()) ?? false;
  bool touch(String connectionId, String key) {
    final newlyAwake = !isAwake(key);
    stopSession(key);
    final entry = _AwakeSession(connectionId, _clock().add(idleTimeout));
    _entries[key] = entry;
    void expire() {
      if (!identical(_entries[key], entry)) return;
      final remaining = entry.until.difference(_clock());
      if (remaining > Duration.zero) {
        entry.timer = Timer(remaining, expire);
        return;
      }
      _entries.remove(key);
      onSleep?.call(connectionId, key);
    }

    entry.timer = Timer(idleTimeout, expire);
    return newlyAwake;
  }

  void stopSession(String key) => _entries.remove(key)?.timer?.cancel();
  void stopConnection(String id) {
    for (final key
        in _entries.keys
            .where((key) => _entries[key]!.connectionId == id)
            .toList()) {
      stopSession(key);
    }
  }

  void close() {
    for (final key in _entries.keys.toList()) {
      stopSession(key);
    }
  }
}

class _AwakeSession {
  final String connectionId;
  final DateTime until;
  Timer? timer;
  _AwakeSession(this.connectionId, this.until);
}
