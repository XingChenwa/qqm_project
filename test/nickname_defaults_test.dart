import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory testDirectory;

  setUp(() async {
    testDirectory = await Directory.systemTemp.createTemp('qqm-nickname-test-');
    Hive.init(testDirectory.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await Hive.close();
    await testDirectory.delete(recursive: true);
  });

  test('全新安装无需保存设置即默认开启昵称查询，托盘偏好仍默认关闭', () async {
    final storage = StorageService();
    await storage.init();
    expect(storage.getBotConfig().enableOiapiNickname, isTrue);
    expect(storage.getBotConfig().closeToTray, isFalse);
    expect(storage.getBotConfig().appId, isEmpty);
  });

  test('存储初始化自动迁移旧关闭状态且不改变其他配置，主动关闭后重启保持关闭', () async {
    final legacy = BotConfig(
      appId: '100312990',
      clientSecret: 'synthetic-test-secret',
      accessToken: 'synthetic-test-token',
      tokenExpiresAt: 123456789,
      enableOiapiNickname: false,
      closeToTray: true,
      defaultAutoReply: '测试回复',
    ).toMap()..remove('oiapiNicknameDefaultVersion');
    legacy['extraLegacyField'] = '保留旧版扩展';
    SharedPreferences.setMockInitialValues({'bot_config': jsonEncode(legacy)});
    final storage = StorageService();
    await storage.init();
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('bot_config')!), {
      ...legacy,
      'enableOiapiNickname': true,
      'oiapiNicknameDefaultVersion': BotConfig.oiapiNicknameDefaultVersion,
    });
    expect(storage.getBotConfig().enableOiapiNickname, isTrue);

    final config = storage.getBotConfig()..enableOiapiNickname = false;
    await storage.saveBotConfig(config);
    final beforeRestart = prefs.getString('bot_config');
    final restarted = StorageService();
    await restarted.init();
    expect(restarted.getBotConfig().enableOiapiNickname, isFalse);
    expect(restarted.getBotConfig().closeToTray, isTrue);
    expect(prefs.getString('bot_config'), beforeRestart);
  });
}
