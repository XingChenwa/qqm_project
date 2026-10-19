import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../server/src/admin_auth.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('qqm-admin-auth-test-');
  });
  tearDown(() async {
    expect(directory.path, contains('qqm-admin-auth-test-'));
    await directory.delete(recursive: true);
  });

  Future<String> code(AdminAuth auth) async =>
      (await File(auth.setupTokenPath).readAsString()).trim();
  const password = 'only-for-offline-tests-2026';

  test('首次安装只生成本地初始化码，重启仍必须设置密码', () async {
    final auth = await AdminAuth.open(directory);
    expect(auth.isConfigured, isFalse);
    expect(await auth.verifyPassword(await code(auth)), isFalse);
    expect(
      await File('${directory.path}/admin-password.txt').exists(),
      isFalse,
    );
    expect(await File('${directory.path}/admin-auth.json').exists(), isFalse);
    final restarted = await AdminAuth.open(directory);
    expect(restarted.isConfigured, isFalse);
    expect(restarted.acceptsSetupToken(await code(auth)), isTrue);
  });

  test('必须验证初始化码、密码长度与确认输入，失败不消耗初始化码', () async {
    final auth = await AdminAuth.open(directory);
    final token = await code(auth);
    for (final entry in [
      ('wrong-code', password, password),
      (token, 'short', 'short'),
      (token, password, '$password-other'),
      (token, '              ', '              '),
      (token, 'invalid\npassword-2026', 'invalid\npassword-2026'),
    ]) {
      await expectLater(
        auth.configure(
          token: entry.$1,
          password: entry.$2,
          confirmation: entry.$3,
        ),
        throwsFormatException,
      );
    }
    expect(auth.isConfigured, isFalse);
    expect(auth.acceptsSetupToken(token), isTrue);
    expect(await code(auth), token);
  });

  test('设置密码后只保存加盐KDF哈希，重启可登录且不能重放初始化', () async {
    final auth = await AdminAuth.open(directory);
    final token = await code(auth);
    await auth.configure(
      token: token,
      password: password,
      confirmation: password,
    );
    expect(auth.isConfigured, isTrue);
    expect(await File(auth.setupTokenPath).exists(), isFalse);
    expect(auth.acceptsSetupToken(token), isFalse);
    final raw = await File('${directory.path}/admin-auth.json').readAsString();
    final record = jsonDecode(raw) as Map;
    expect(raw.contains(password), isFalse);
    expect(raw.contains(token), isFalse);
    expect(record['algorithm'], 'pbkdf2-hmac-sha256');
    expect(record['iterations'], 600000);
    expect(base64Decode(record['salt']).length, 32);
    final restarted = await AdminAuth.open(directory);
    expect(restarted.isConfigured, isTrue);
    expect(await restarted.verifyPassword(password), isTrue);
    expect(await restarted.verifyPassword('$password-other'), isFalse);
    await expectLater(
      restarted.configure(
        token: token,
        password: password,
        confirmation: password,
      ),
      throwsStateError,
    );
    expect(await File(auth.setupTokenPath).exists(), isFalse);
  });

  test('并发初始化只允许一个设置请求，不会后到覆盖先到', () async {
    final auth = await AdminAuth.open(directory);
    final token = await code(auth);
    final first = auth.configure(
      token: token,
      password: password,
      confirmation: password,
    );
    await expectLater(
      auth.configure(
        token: token,
        password: '$password-second',
        confirmation: '$password-second',
      ),
      throwsStateError,
    );
    await first;
    expect(await auth.verifyPassword(password), isTrue);
  });

  test('旧版随机密码仅用于本地初始化验证，必须重新设置密码，保留其他数据', () async {
    const oldCode = 'legacy-generated-password-code-12345678';
    final legacy = File('${directory.path}/admin-password.txt');
    await legacy.writeAsString(oldCode);
    final existingData = File('${directory.path}/bot-data-fixture.txt');
    await existingData.writeAsString('preserve-existing-bot-config-and-chat');
    final auth = await AdminAuth.open(directory);
    expect(auth.isConfigured, isFalse);
    expect(await auth.verifyPassword(oldCode), isFalse);
    expect(auth.acceptsSetupToken(oldCode), isTrue);
    await auth.configure(
      token: oldCode,
      password: password,
      confirmation: password,
    );
    expect(await auth.verifyPassword(password), isTrue);
    expect(await legacy.exists(), isFalse);
    expect(
      await existingData.readAsString(),
      'preserve-existing-bot-config-and-chat',
    );
  });

  test('损坏的密码文件不能重新初始化或覆盖，不在错误里显示原文件内容', () async {
    final file = File('${directory.path}/admin-auth.json');
    const corrupted = '{"private-data":"never-print-this",bad';
    await file.writeAsString(corrupted);
    try {
      await AdminAuth.open(directory);
      fail('必须拒绝损坏的密码配置');
    } on FormatException catch (error) {
      expect(error.toString(), isNot(contains('never-print-this')));
    }
    expect(await file.readAsString(), corrupted);
    expect(await File('${directory.path}/setup-token.txt').exists(), isFalse);
  });

  test('密码文件路径不能是目录或符号链接', () async {
    await Directory('${directory.path}/setup-token.txt').create();
    await expectLater(AdminAuth.open(directory), throwsFormatException);
  });

  test('Linux 数据目录和认证文件仅当前用户可读写', () async {
    final auth = await AdminAuth.open(directory);
    final dirMode = await Process.run('stat', ['-c', '%a', directory.path]);
    final codeMode = await Process.run('stat', [
      '-c',
      '%a',
      auth.setupTokenPath,
    ]);
    expect(dirMode.stdout.toString().trim(), '700');
    expect(codeMode.stdout.toString().trim(), '600');
    final other = File('${directory.path}/target.txt');
    await other.writeAsString('must-not-overwrite');
    await File(auth.setupTokenPath).delete();
    await Link(auth.setupTokenPath).create(other.path);
    await expectLater(AdminAuth.open(directory), throwsFormatException);
    expect(await other.readAsString(), 'must-not-overwrite');
  }, skip: !Platform.isLinux);
}
