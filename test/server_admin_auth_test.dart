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
  const entrance = 'offline-admin-entrance';

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
          entrance: entrance,
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
      entrance: entrance,
    );
    expect(auth.isConfigured, isTrue);
    expect(auth.isReady, isTrue);
    expect(auth.entrance, entrance);
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
        entrance: entrance,
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
      entrance: entrance,
    );
    await expectLater(
      auth.configure(
        token: token,
        password: '$password-second',
        confirmation: '$password-second',
        entrance: entrance,
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
      entrance: entrance,
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

  test('安全入口必须合法且不可利用路径编码或保留路由绕过', () async {
    final auth = await AdminAuth.open(directory);
    final token = await code(auth);
    for (final value in [
      '',
      'xxxx',
      '../private',
      'api/state',
      '/admin-panel',
      'health?x',
      'admin%2fsecret',
      r'admin\secret',
      'a' * 65,
      '管理员入口-123',
    ]) {
      await expectLater(
        auth.configure(
          token: token,
          password: password,
          confirmation: password,
          entrance: value,
        ),
        throwsFormatException,
      );
    }
    expect(auth.isConfigured, isFalse);
    expect(auth.acceptsSetupToken(token), isTrue);
  });

  test('私有访问链接只从本地显式取得，初始化码放片段且配置后不再返回', () async {
    final auth = await AdminAuth.open(directory);
    final origin = Uri.parse('http://192.0.2.10:23336');
    final link = await auth.accessLink(origin);
    expect(link.fragment, 'setup=${await code(auth)}');
    expect(link.query, isEmpty);
    expect(link.path, '/');
    for (final bad in [
      'ftp://192.0.2.10',
      'http://user@localhost',
      'http://localhost/path',
      'http://localhost/?token=1',
      'http://localhost/#code',
      'http://localhost:0',
      'http://localhost:99999',
    ]) {
      await expectLater(auth.accessLink(Uri.parse(bad)), throwsFormatException);
    }
    await auth.configure(
      token: await code(auth),
      password: password,
      confirmation: password,
      entrance: entrance,
    );
    expect((await auth.accessLink(origin)).toString(), '$origin/$entrance/');
  });

  test('已有 v1 密码保留哈希，先登录补入口，不重新开放初始化', () async {
    final auth = await AdminAuth.open(directory);
    await auth.configure(
      token: await code(auth),
      password: password,
      confirmation: password,
      entrance: entrance,
    );
    final file = File('${directory.path}/admin-auth.json');
    final record =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    record['version'] = 1;
    record.remove('entrance');
    await file.writeAsString(jsonEncode(record));
    final legacy = await AdminAuth.open(directory);
    expect(legacy.isConfigured, isTrue);
    expect(legacy.isReady, isFalse);
    expect(legacy.needsEntrance, isTrue);
    expect(await legacy.verifyPassword(password), isTrue);
    expect(await File(legacy.setupTokenPath).exists(), isFalse);
    await legacy.configureEntrance('upgraded-private-entrance');
    final restarted = await AdminAuth.open(directory);
    expect(restarted.isReady, isTrue);
    expect(restarted.entrance, 'upgraded-private-entrance');
    expect(await restarted.verifyPassword(password), isTrue);
    final updated = jsonDecode(await file.readAsString()) as Map;
    expect(updated['hash'], record['hash']);
    expect(updated['salt'], record['salt']);
    await expectLater(
      restarted.configureEntrance('cannot-replace-entrance'),
      throwsStateError,
    );
  });

  test('v2 配置缺少或损坏安全入口时失败关闭，不降级到根地址', () async {
    final auth = await AdminAuth.open(directory);
    await auth.configure(
      token: await code(auth),
      password: password,
      confirmation: password,
      entrance: entrance,
    );
    final file = File('${directory.path}/admin-auth.json');
    final record = jsonDecode(await file.readAsString()) as Map;
    record.remove('entrance');
    await file.writeAsString(jsonEncode(record));
    await expectLater(AdminAuth.open(directory), throwsFormatException);
    expect(await File(auth.setupTokenPath).exists(), isFalse);
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
