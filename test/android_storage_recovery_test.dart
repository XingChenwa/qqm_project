import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/ui/widgets/startup_gate.dart';
import 'support/fakes.dart';

class TemporarilyUnavailablePreferences extends InMemorySharedPreferencesStore {
  bool ready = false;
  String errorCode = 'channel-error';
  TemporarilyUnavailablePreferences(super.data) : super.withData();
  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) {
    if (!ready) {
      throw PlatformException(
        code: errorCode,
        message: 'private-config-not-for-diagnostics',
      );
    }
    return super.getAllWithParameters(parameters);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cn.uuze.botmanager/runtime');
  late Directory root;
  late SharedPreferencesStorePlatform previous;
  setUp(() async {
    previous = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    root = await Directory.systemTemp.createTemp('qqm-storage-recovery-');
    Hive.init(root.path);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
    debugDefaultTargetPlatformOverride = null;
    await Hive.close();
    await root.delete(recursive: true);
  });

  test('Android 通道错误只重注册并重读一次，机器人凭据和原有聊天均不清空', () async {
    final config = validConfig();
    final prefs = TemporarilyUnavailablePreferences({
      'flutter.bot_config': jsonEncode(config.toMap()),
      'flutter.theme_dark': true,
    });
    SharedPreferencesStorePlatform.instance = prefs;
    final messages = await Hive.openBox<String>('messages');
    await messages.put(
      'old-msg',
      jsonEncode(
        incoming('old-msg', session: 'old-session', content: '保留的聊天').toMap(),
      ),
    );
    var repairs = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'repairPreferences');
          repairs++;
          prefs.ready = true;
          return true;
        });
    final stages = <String>[];
    final storage = StorageService();
    await storage.init(report: stages.add);
    expect(repairs, 1);
    expect(stages, contains('读取系统偏好设置'));
    expect(stages, contains('恢复 Android 偏好设置通道（保留本地数据）'));
    expect(storage.getBotConfig().clientSecret, config.clientSecret);
    expect(storage.getMessages('old-session').single.content, '保留的聊天');
    expect(storage.getAppearance(), 'dark');
    await storage.setAppearance('system');
    expect(storage.getAppearance(), 'system');
  });

  test('其他平台错误不重试，不写空配置，不把真实错误伪装成初始化成功', () async {
    final prefs = TemporarilyUnavailablePreferences({})
      ..errorCode = 'storage_error';
    SharedPreferencesStorePlatform.instance = prefs;
    var repairs = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          repairs++;
          return true;
        });
    await expectLater(
      StorageService().init(),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'storage_error'),
      ),
    );
    expect(repairs, 0);
  });

  test('诊断即使没有堆栈也包含通道和错误码，不输出密钥、message 或 details', () {
    final diagnostic = startupDiagnostic(
      '读取系统偏好设置',
      PlatformException(
        code: 'channel-error',
        message:
            'Unable to establish dev.flutter.pigeon.shared_preferences_android.LegacySharedPreferencesApi.getAll private-config-not-for-diagnostics',
        details: {'clientSecret': 'secret-must-not-appear'},
      ),
      StackTrace.empty,
    );
    expect(diagnostic, contains('平台错误码：channel-error'));
    expect(diagnostic, contains('LegacySharedPreferencesApi.getAll'));
    expect(diagnostic, isNot(contains('private-config-not-for-diagnostics')));
    expect(diagnostic, isNot(contains('secret-must-not-appear')));
  });
}
