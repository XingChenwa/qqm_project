import 'models.dart';
import 'store.dart';

/// Read-only configuration snapshots. Large base64 assets are decoded only when
/// their category changes, never during runtime liveness checks or UI rebuilds.
class AgentSnapshotCache<T> {
  int _version = -1;
  List<T> _values = const [];
  List<T> read(AgentStore store, String prefix, T Function(Json) decode) {
    final revision = store.version(prefix);
    if (revision != _version) {
      _values = List<T>.unmodifiable(store.all(prefix).map(decode));
      _version = revision;
    }
    return _values;
  }
}

Object? readOnlyAgentValue(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      value.map(
        (key, item) => MapEntry(key.toString(), readOnlyAgentValue(item)),
      ),
    );
  }
  if (value is List) {
    return List<dynamic>.unmodifiable(value.map(readOnlyAgentValue));
  }
  return value;
}

Json readOnlyAgentJson(Json value) => readOnlyAgentValue(value) as Json;
