import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'android_preferences_store.dart';
export 'package:shared_preferences/shared_preferences.dart'
    show SharedPreferences;

/// Retry only preference loading, not Hive or config migration. The alternate
/// host calls the SAME legacy store through a standard MethodChannel; it never
/// supplies empty defaults or moves/deletes existing data.
Future<SharedPreferences> loadPreferences({
  void Function(String)? report,
}) async {
  try {
    return await SharedPreferences.getInstance();
  } catch (error, stack) {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        (error is! PlatformException && error is! MissingPluginException)) {
      rethrow;
    }
    report?.call('使用 Android 原生备用通道读取偏好设置（保留本地数据）');
    try {
      return await AndroidPreferencesStore.activate();
    } catch (fallback, fallbackStack) {
      Error.throwWithStackTrace(
        PreferenceInitializationException(error, fallback, stack),
        fallbackStack,
      );
    }
  }
}
