import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

/// First installation must be claimed with a local, one-use setup code before
/// any password can be set. Neither this code nor a password is served via HTTP.
class AdminAuth {
  static const _iterations = 600000;
  static const _algorithm = 'pbkdf2-hmac-sha256';
  final Directory data;
  Map<String, dynamic>? _record;
  List<int>? _setupHash;
  bool _setting = false;

  AdminAuth._(this.data);

  File get _passwordFile => File(p.join(data.path, 'admin-auth.json'));
  File get _legacyFile => File(p.join(data.path, 'admin-password.txt'));
  File get _setupFile => File(p.join(data.path, 'setup-token.txt'));
  String get setupTokenPath => _setupFile.path;
  bool get isConfigured => _record != null;

  static Future<AdminAuth> open(Directory data) async {
    await data.create(recursive: true);
    await _private(data.path, '700');
    final result = AdminAuth._(data);
    for (final file in [
      result._passwordFile,
      result._setupFile,
      result._legacyFile,
    ]) {
      await _checkRegular(file);
    }
    if (await result._passwordFile.exists()) {
      await _private(result._passwordFile.path, '600');
      result._record = await _readRecord(result._passwordFile);
      return result;
    }
    if (!await result._setupFile.exists()) {
      // An older release's generated password can prove control of an existing
      // installation, but cannot bypass choosing a personal management password.
      final code = await result._legacyFile.exists()
          ? await _readCode(result._legacyFile)
          : base64Url.encode(_randomBytes(32)).replaceAll('=', '');
      await result._setupFile.create(exclusive: true);
      await _private(result._setupFile.path, '600');
      await result._setupFile.writeAsString(code, flush: true);
    }
    await _private(result._setupFile.path, '600');
    result._setupHash = sha256
        .convert(utf8.encode(await _readCode(result._setupFile)))
        .bytes;
    return result;
  }

  bool acceptsSetupToken(String token) =>
      !isConfigured &&
      _setupHash != null &&
      _equal(sha256.convert(utf8.encode(token.trim())).bytes, _setupHash!);

  Future<void> configure({
    required String token,
    required String password,
    required String confirmation,
  }) async {
    if (isConfigured || _setting) throw StateError('管理密码已设置或正在设置，请使用密码登录');
    if (!acceptsSetupToken(token)) {
      throw const FormatException('初始化码不正确，请在服务器本地查看 setup-token.txt');
    }
    if (password != confirmation) throw const FormatException('两次输入的管理密码不一致');
    if (password.runes.length < 12 ||
        password.length > 256 ||
        password.trim().isEmpty ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(password)) {
      throw const FormatException('管理密码需为 12–256 个字符，不能只含空白或控制字符');
    }
    _setting = true;
    File? pending;
    try {
      final salt = _randomBytes(32);
      final hash = await _derive(password, salt);
      final record = <String, dynamic>{
        'version': 1,
        'algorithm': _algorithm,
        'iterations': _iterations,
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
      };
      await _checkRegular(_passwordFile);
      if (await _passwordFile.exists()) {
        throw StateError('已有管理密码配置，不会覆盖；请重启后登录');
      }
      pending = File(
        p.join(
          data.path,
          '.admin-auth-${base64Url.encode(_randomBytes(12))}.tmp',
        ),
      );
      await pending.create(exclusive: true);
      await _private(pending.path, '600');
      await pending.writeAsString(jsonEncode(record), flush: true);
      await pending.rename(_passwordFile.path);
      pending = null;
      _record = record;
      _setupHash = null;
      // Only remove obsolete one-use credentials after the hash is durable.
      for (final file in [_setupFile, _legacyFile]) {
        try {
          await _checkRegular(file);
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // A leftover code is inert once admin-auth.json exists.
        }
      }
    } finally {
      if (pending != null && await pending.exists()) await pending.delete();
      _setting = false;
    }
  }

  Future<bool> verifyPassword(String password) async {
    final record = _record;
    if (record == null || password.length > 256) return false;
    final hash = await _derive(
      password,
      base64Decode(record['salt'] as String),
    );
    return _equal(hash, base64Decode(record['hash'] as String));
  }

  static Future<List<int>> _derive(String password, List<int> salt) async {
    // OWASP Password Storage Cheat Sheet: PBKDF2-HMAC-SHA256 >= 600,000.
    final key = await Pbkdf2.hmacSha256(
      iterations: _iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: password, nonce: salt);
    return key.extractBytes();
  }

  static Future<Map<String, dynamic>> _readRecord(File file) async {
    try {
      if (await file.length() > 4096) throw const FormatException();
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> ||
          value['version'] != 1 ||
          value['algorithm'] != _algorithm ||
          value['iterations'] != _iterations ||
          value['salt'] is! String ||
          value['hash'] is! String ||
          base64Decode(value['salt'] as String).length != 32 ||
          base64Decode(value['hash'] as String).length != 32) {
        throw const FormatException();
      }
      return value;
    } on FormatException {
      // Never render a malformed JSON source: it may contain credentials.
      throw const FormatException('管理密码配置损坏；为保护已有数据，不会重置或开放初始化');
    }
  }

  static Future<String> _readCode(File file) async {
    if (await file.length() > 512) {
      throw const FormatException('初始化码文件无效，不会覆盖已有文件');
    }
    final code = (await file.readAsString()).trim();
    if (code.length < 24 || code.length > 256) {
      throw const FormatException('初始化码文件无效，不会覆盖已有文件');
    }
    return code;
  }

  static Future<void> _checkRegular(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FormatException('管理密码与初始化码必须为普通文件，不能使用符号链接');
    }
  }

  static Future<void> _private(String path, String mode) async {
    if (!Platform.isWindows &&
        (await Process.run('chmod', [mode, path])).exitCode != 0) {
      throw const FileSystemException('无法设置管理密码目录或文件的私有权限');
    }
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List.generate(length, (_) => random.nextInt(256));
  }

  static bool _equal(List<int> a, List<int> b) {
    var diff = a.length ^ b.length;
    for (var i = 0; i < a.length && i < b.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
