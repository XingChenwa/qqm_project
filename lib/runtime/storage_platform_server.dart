import 'dart:convert';
import 'package:hive/hive.dart';

// Kept in the server's private data directory, never in the HTTP asset tree.
class SharedPreferences {
  final Box<String> _box;
  SharedPreferences._(this._box);
  static Future<SharedPreferences> getInstance() async =>
      SharedPreferences._(await Hive.openBox<String>('server_preferences'));
  String? getString(String key) {
    final raw = _box.get(key);
    return raw == null ? null : jsonDecode(raw) as String?;
  }

  bool? getBool(String key) {
    final raw = _box.get(key);
    return raw == null ? null : jsonDecode(raw) as bool?;
  }

  bool containsKey(String key) => _box.containsKey(key);
  Future<bool> setString(String key, String value) async {
    await _box.put(key, jsonEncode(value));
    return true;
  }

  Future<bool> setBool(String key, bool value) async {
    await _box.put(key, jsonEncode(value));
    return true;
  }

  Future<bool> clear() async {
    await _box.clear();
    return true;
  }
}

Future<SharedPreferences> loadPreferences({void Function(String)? report}) =>
    SharedPreferences.getInstance();
