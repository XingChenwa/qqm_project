import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:qq_bot_manager/runtime/android_preferences_store.dart';
import 'package:qq_bot_manager/runtime/storage_platform_flutter.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/services/update_preferences.dart';
import 'package:qq_bot_manager/ui/widgets/startup_gate.dart';
import 'support/fakes.dart';

class UnavailablePreferences extends InMemorySharedPreferencesStore {
  Object error;
  UnavailablePreferences(this.error) : super.empty();
  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters p) async =>
      throw error;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SharedPreferencesStorePlatform previous;
  final disk = <String, Object>{};
  final calls = <MethodCall>[];
  setUp(() async {
    previous = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    root = await Directory.systemTemp.createTemp('qqm-storage-recovery-');
    Hive.init(root.path);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    disk.clear();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidPreferencesStore.channel, (
          call,
        ) async {
          calls.add(call);
          final args = Map<String, dynamic>.from(call.arguments as Map);
          switch (call.method) {
            case 'getAll':
              return {
                for (final entry in disk.entries)
                  if (entry.key.startsWith(args['prefix'] as String) &&
                      (args['allowList'] == null ||
                          (args['allowList'] as List).contains(entry.key)))
                    entry.key: entry.value,
              };
            case 'clear':
              disk.removeWhere(
                (key, _) =>
                    key.startsWith(args['prefix'] as String) &&
                    (args['allowList'] == null ||
                        (args['allowList'] as List).contains(key)),
              );
            case 'remove':
              disk.remove(args['key']);
            default:
              disk[args['key'] as String] = args['value'] as Object;
          }
          return true;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidPreferencesStore.channel, null);
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
    debugDefaultTargetPlatformOverride = null;
    await Hive.close();
    await root.delete(recursive: true);
  });

  for (final error in [
    PlatformException(code: 'PlatformException'),
    PlatformException(code: 'channel-error'),
    MissingPluginException('private-config-not-for-diagnostics'),
  ]) {
    test('Android ${error.runtimeType} 使用同一份原生偏好设置，保留凭据和聊天', () async {
      final config = validConfig();
      disk.addAll({
        'flutter.bot_config': jsonEncode(config.toMap()),
        'flutter.theme_dark': true,
        'flutter.updates_beta_highest_build': 25,
      });
      SharedPreferencesStorePlatform.instance = UnavailablePreferences(error);
      final messages = await Hive.openBox<String>('messages');
      await messages.put(
        'old-msg',
        jsonEncode(
          incoming('old-msg', session: 'old-session', content: '保留的聊天').toMap(),
        ),
      );
      final stages = <String>[];
      final storage = StorageService();
      await storage.init(report: stages.add);
      expect(stages, contains('使用 Android 原生备用通道读取偏好设置（保留本地数据）'));
      expect(storage.getBotConfig().clientSecret, config.clientSecret);
      expect(storage.getMessages('old-session').single.content, '保留的聊天');
      expect(storage.getAppearance(), 'dark');
      await storage.setAppearance('system');
      expect(disk['flutter.appearance'], 'system');
      // Bootstrap, onboarding and update options must share the recovered store.
      final prefs = await SharedPreferences.getInstance();
      final updates = UpdatePreferences(prefs);
      await updates.rememberGitHubBuild(26);
      expect(disk['flutter.updates_github_highest_build'], 26);
      expect(calls.where((c) => c.method == 'clear'), isEmpty);
      expect(disk['flutter.bot_config'], isNotNull);
    });
  }

  test('备用通道失败不伪造空配置，也不清空或替换原有存储', () async {
    final primary = UnavailablePreferences(
      PlatformException(code: 'PlatformException'),
    );
    SharedPreferencesStorePlatform.instance = primary;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidPreferencesStore.channel, (
          call,
        ) async {
          calls.add(call);
          throw PlatformException(
            code: 'PREFERENCES_READ_FAILED',
            message: 'secret-must-not-appear',
            details: {'cause': 'IOException'},
          );
        });
    await expectLater(
      StorageService().init(),
      throwsA(isA<PreferenceInitializationException>()),
    );
    expect(SharedPreferencesStorePlatform.instance, same(primary));
    expect(calls.map((c) => c.method), ['getAll']);
  });

  test('空响应不是空数据库；存储失败不能继续写入默认配置', () async {
    SharedPreferencesStorePlatform.instance = UnavailablePreferences(
      PlatformException(code: 'channel-error'),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          AndroidPreferencesStore.channel,
          (_) async => null,
        );
    await expectLater(
      loadPreferences(),
      throwsA(
        isA<PreferenceInitializationException>().having(
          (e) => (e.fallback as PlatformException).code,
          'fallback',
          'PREFERENCES_EMPTY_REPLY',
        ),
      ),
    );
  });

  test('不对配置解析错误或其他系统调用切换存储，非安卓仍使用原插件', () async {
    final invalid = FormatException('private-config-not-for-diagnostics');
    SharedPreferencesStorePlatform.instance = UnavailablePreferences(invalid);
    await expectLater(loadPreferences(), throwsA(same(invalid)));
    expect(calls, isEmpty);
    SharedPreferences.resetStatic();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final error = PlatformException(code: 'PlatformException');
    SharedPreferencesStorePlatform.instance = UnavailablePreferences(error);
    await expectLater(loadPreferences(), throwsA(same(error)));
    expect(calls, isEmpty);
  });

  test('备用传输保留 bool/int/double/新旧列表编码、前缀过滤和删除语义', () async {
    SharedPreferencesStorePlatform.instance = UnavailablePreferences(
      PlatformException(code: 'PlatformException'),
    );
    disk.addAll({
      'flutter.enabled': true,
      'flutter.count': 25,
      'flutter.ratio': 1.5,
      'flutter.oldList': ['a', 'b'],
      'flutter.newList': '${AndroidPreferencesStore.jsonListPrefix}["c","d"]',
      'not-flutter': 'untouched',
    });
    final prefs = await loadPreferences();
    expect(prefs.getBool('enabled'), true);
    expect(prefs.getInt('count'), 25);
    expect(prefs.getDouble('ratio'), 1.5);
    expect(prefs.getStringList('oldList'), ['a', 'b']);
    expect(prefs.getStringList('newList'), ['c', 'd']);
    expect(prefs.containsKey('not-flutter'), false);
    await prefs.setStringList('newList', ['x']);
    await prefs.reload();
    expect(prefs.getStringList('newList'), ['x']);
    await prefs.remove('count');
    expect(disk.containsKey('flutter.count'), false);
    await prefs.clear();
    expect(disk, {'not-flutter': 'untouched'});
  });

  test('诊断展示已知错误码和原生类别，不输出密钥、message 或任意 details', () {
    final original = PlatformException(
      code: 'channel-error',
      message:
          'Unable to establish dev.flutter.pigeon.shared_preferences_android.SharedPreferencesApi.getAll private-config-not-for-diagnostics',
      details: {'clientSecret': 'secret-must-not-appear'},
    );
    final diagnostic = startupDiagnostic(
      '读取系统偏好设置',
      PreferenceInitializationException(
        original,
        PlatformException(
          code: 'PREFERENCES_READ_FAILED',
          message: 'secret-must-not-appear',
          details: {'cause': 'IOException', 'config': 'secret-must-not-appear'},
        ),
        StackTrace.empty,
      ),
      StackTrace.empty,
    );
    expect(diagnostic, contains('平台错误码：channel-error'));
    expect(diagnostic, contains('SharedPreferencesApi.getAll'));
    expect(diagnostic, contains('原生异常类别：IOException'));
    expect(diagnostic, contains('堆栈：平台未提供'));
    expect(diagnostic, isNot(contains('private-config-not-for-diagnostics')));
    expect(diagnostic, isNot(contains('secret-must-not-appear')));
  });
  test('备用读取遇到损坏列表不跳过或覆盖，诊断不包含原始值', () async {
    SharedPreferencesStorePlatform.instance = UnavailablePreferences(
      PlatformException(code: 'PlatformException'),
    );
    final raw =
        '${AndroidPreferencesStore.jsonListPrefix}secret-must-not-appear';
    disk['flutter.list'] = raw;
    await expectLater(
      loadPreferences(),
      throwsA(
        isA<PreferenceInitializationException>().having(
          (e) => (e.fallback as PlatformException).code,
          'code',
          'PREFERENCES_INVALID_LIST',
        ),
      ),
    );
    expect(disk['flutter.list'], raw);
    expect(calls.where((c) => c.method != 'getAll'), isEmpty);
    final report = startupDiagnostic(
      '读取系统偏好设置',
      PlatformException(
        code: 'secret-must-not-appear',
        message: raw,
        details: {'cause': raw},
      ),
      StackTrace.empty,
    );
    expect(report, isNot(contains('secret-must-not-appear')));
  });
}
