/// Redact JSON strings, not serialized tokens: a secret such as "1" must never
/// turn a numeric field or a boolean into invalid JSON.
Object? redactAgentValue(Object? value, Iterable<String> secrets) {
  final values = secrets.where((s) => s.isNotEmpty).toSet().toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  Object? visit(Object? item) {
    if (item is String) {
      var result = item;
      for (final secret in values) {
        result = result.replaceAll(secret, '[已隐藏]');
      }
      return result;
    }
    if (item is List) return item.map(visit).toList();
    if (item is Map) {
      return item.map(
        (key, entry) => MapEntry(visit(key.toString()) as String, visit(entry)),
      );
    }
    return item;
  }

  return visit(value);
}
