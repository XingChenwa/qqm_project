import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// Does not export exception bodies: they may include stored configuration.
class PreferenceInitializationException implements Exception {
  final Object primary, fallback;
  final StackTrace primaryStack;
  const PreferenceInitializationException(
    this.primary,
    this.fallback,
    this.primaryStack,
  );
  @override
  String toString() => 'Android 偏好设置的两个读取通道均未完成；本地数据未清除。';
}

/// An alternative transport, not an alternative database. All consumers of
/// SharedPreferences (including onboarding/updates) keep the same singleton.
class AndroidPreferencesStore extends SharedPreferencesStorePlatform {
  static const channel = MethodChannel('cn.uuze.botmanager/preferences');
  static const jsonListPrefix = 'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu!';

  static Future<SharedPreferences> activate() async {
    final store = AndroidPreferencesStore();
    // Never install an empty/in-memory fallback if the native host is missing.
    await store.getAll();
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = store;
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      SharedPreferencesStorePlatform.instance = previous;
      rethrow;
    }
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
    GetAllParameters(filter: PreferencesFilter(prefix: 'flutter.')),
  );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final raw = await channel.invokeMapMethod<String, Object>('getAll', {
      'prefix': parameters.filter.prefix,
      'allowList': parameters.filter.allowList?.toList(),
    });
    if (raw == null) {
      throw PlatformException(code: 'PREFERENCES_EMPTY_REPLY');
    }
    final values = Map<String, Object>.from(raw);
    for (final entry in values.entries.toList()) {
      final value = entry.value;
      if (value is String && value.startsWith(jsonListPrefix)) {
        try {
          values[entry.key] =
              (jsonDecode(value.substring(jsonListPrefix.length)) as List)
                  .cast<String>()
                  .toList();
        } catch (_) {
          // Fail closed, preserving the raw stored value. No key or contents
          // are attached to the diagnostic exception.
          throw PlatformException(code: 'PREFERENCES_INVALID_LIST');
        }
      }
    }
    return values;
  }

  Future<bool> _write(String method, Map<String, Object?> args) async {
    final result = await channel.invokeMethod<bool>(method, args);
    if (result == null) {
      throw PlatformException(code: 'PREFERENCES_EMPTY_REPLY');
    }
    return result;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (!{
      'Bool',
      'Int',
      'Double',
      'String',
      'StringList',
    }.contains(valueType)) {
      throw ArgumentError.value(valueType, 'valueType');
    }
    return _write('set$valueType', {
      'key': key,
      'value': valueType == 'StringList'
          ? '$jsonListPrefix${jsonEncode(value)}'
          : value,
    });
  }

  @override
  Future<bool> remove(String key) => _write('remove', {'key': key});

  @override
  Future<bool> clear() => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: 'flutter.')),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) =>
      _write('clear', {
        'prefix': parameters.filter.prefix,
        'allowList': parameters.filter.allowList?.toList(),
      });
}
