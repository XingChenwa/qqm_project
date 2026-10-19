import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
export 'package:shared_preferences/shared_preferences.dart'
    show SharedPreferences;

bool needsPreferenceRepair(Object error) =>
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.android &&
    error is PlatformException &&
    {'channel-error', 'missing-plugin'}.contains(error.code);

Future<void> repairPreferences() async {
  await const MethodChannel(
    'cn.uuze.botmanager/runtime',
  ).invokeMethod<bool>('repairPreferences');
  final preferences = await SharedPreferences.getInstance();
  await preferences.reload();
}
