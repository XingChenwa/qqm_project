import 'dart:convert';
import 'package:hive/hive.dart';
import 'models.dart';

/// No official bot adapters, preferences, database names or migrations.
class AgentStore {
  final Map<String, Json> _memory;
  Box<String>? _box;
  final bool memoryOnly;
  bool _ready = false;
  int _revision = 0, _openedRevision = 0;
  final _versions = <String, int>{}, _keyVersions = <String, int>{};

  /// Configuration revisions never deserialize a package or its bundled assets.
  int version(String prefix) {
    final value = _versions[prefix] ?? 0;
    return value > _openedRevision ? value : _openedRevision;
  }

  int keyVersion(String key) {
    final value = _keyVersions[key] ?? 0;
    return value > _openedRevision ? value : _openedRevision;
  }

  void _touch(String key) {
    _revision++;
    _versions[key.split(':').first] = _revision;
    _keyVersions[key] = _revision;
  }

  bool get isOpen => _ready;
  Future<void> _writes = Future.value();
  AgentStore() : memoryOnly = false, _memory = {};
  AgentStore.memory() : memoryOnly = true, _memory = {};
  List<String> get keys => memoryOnly
      ? _memory.keys.toList()
      : (_box?.keys.cast<String>().toList() ?? []);
  Future<void> open() async {
    if (_ready) return;
    if (!memoryOnly) _box = await Hive.openBox<String>('qqm_agent_v1');
    _openedRevision = ++_revision;
    _ready = true;
  }

  Json? get(String key) {
    final raw = memoryOnly ? _memory[key] : _box?.get(key);
    if (raw == null) return null;
    return object(jsonDecode(raw is String ? raw : jsonEncode(raw)));
  }

  List<Json> all(String prefix) {
    final keys = memoryOnly
        ? _memory.keys
        : (_box?.keys.cast<String>() ?? <String>[]);
    return keys
        .where((e) => e.startsWith('$prefix:'))
        .map((e) => get(e)!)
        .toList();
  }

  Future<void> put(String key, Json value) {
    final snapshot = jsonEncode(value);
    return _serial(() async {
      if (memoryOnly) {
        _memory[key] = object(jsonDecode(snapshot));
      } else {
        await _box!.put(key, snapshot);
      }
      _touch(key);
    });
  }

  Future<void> remove(String key) => _serial(() async {
    if (memoryOnly) {
      _memory.remove(key);
    } else {
      await _box!.delete(key);
    }
    _touch(key);
  });
  List<AgentMessage> messages(String sessionKey) =>
      (get('history:$sessionKey')?['messages'] as List? ?? [])
          .map((e) => AgentMessage.fromJson(object(e)))
          .toList();
  Future<bool> append(AgentMessage message) async {
    var inserted = false;
    await _serial(() async {
      final list = messages(message.sessionKey);
      if (list.any((e) => e.id == message.id)) return;
      list.add(message);
      if (list.length > 500) list.removeRange(0, list.length - 500);
      final value = {'messages': list.map((e) => e.toJson()).toList()};
      if (memoryOnly) {
        _memory['history:${message.sessionKey}'] = value;
      } else {
        await _box!.put('history:${message.sessionKey}', jsonEncode(value));
      }
      inserted = true;
      _touch('history:${message.sessionKey}');
    });
    return inserted;
  }

  /// Atomic patch so an asynchronous profile result cannot overwrite a newer
  /// mention promotion, auto-reply marker or reply that arrived in the meantime.
  Future<AgentMessage?> updateMessage(
    String sessionKey,
    String id,
    AgentMessage Function(AgentMessage) update,
  ) async {
    AgentMessage? result;
    await _serial(() async {
      final list = messages(sessionKey);
      final index = list.indexWhere((m) => m.id == id);
      if (index < 0) return;
      final value = update(list[index]);
      if (value.id != id || value.sessionKey != sessionKey) {
        throw const AgentException('消息更新不能改变会话归属。');
      }
      list[index] = value;
      result = value;
      final data = {'messages': list.map((m) => m.toJson()).toList()};
      if (memoryOnly) {
        _memory['history:$sessionKey'] = data;
      } else {
        await _box!.put('history:$sessionKey', jsonEncode(data));
      }
      _touch('history:$sessionKey');
    });
    return result;
  }

  Future<bool> enrichSender(
    String sessionKey,
    String senderId,
    String name,
  ) async {
    var changed = false;
    await _serial(() async {
      final list = messages(sessionKey).map((m) {
        if (!m.outgoing &&
            m.senderId == senderId &&
            (m.senderNameIsFallback ||
                m.senderName == senderId ||
                m.senderName.isEmpty)) {
          changed = true;
          return m.copyWith(senderName: name);
        }
        return m;
      }).toList();
      if (!changed) return;
      final data = {'messages': list.map((m) => m.toJson()).toList()};
      if (memoryOnly) {
        _memory['history:$sessionKey'] = data;
      } else {
        await _box!.put('history:$sessionKey', jsonEncode(data));
      }
      _touch('history:$sessionKey');
    });
    return changed;
  }

  Future<void> _serial(Future<void> Function() work) {
    final result = _writes.then((_) => work());
    _writes = result.catchError((Object _) {});
    return result;
  }

  Future<void> addUsage(int input, int output) => _serial(() async {
    final old = get('meta:usage') ?? {};
    final value = {
      'calls': integer(old['calls'], 0) + 1,
      'input': integer(old['input'], 0) + input,
      'output': integer(old['output'], 0) + output,
    };
    if (memoryOnly) {
      _memory['meta:usage'] = value;
    } else {
      await _box!.put('meta:usage', jsonEncode(value));
    }
    _touch('meta:usage');
  });
  Future<int> reserveReplySequence(String key, int limit) async {
    var sequence = 0;
    await _serial(() async {
      final old = get(key);
      sequence = integer(old?['sequence'], 0) + 1;
      if (sequence > limit) {
        throw const AgentException('这条消息的被动回复次数已用完，请等待新消息。');
      }
      final value = {'sequence': sequence};
      if (memoryOnly) {
        _memory[key] = value;
      } else {
        await _box!.put(key, jsonEncode(value));
      }
      _touch(key);
    });
    return sequence;
  }

  Future<void> flush() async {
    await _writes;
    await _box?.flush();
  }

  /// Await committed writes without forcing a filesystem sync for every hook.
  Future<void> settled() async => await _writes;

  Future<void> close() async {
    await flush();
    await _box?.close();
    _ready = false;
    _openedRevision = ++_revision;
  }
}
