import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/models/app_release.dart';

AppRelease release(
  String platform,
  String format, {
  String version = '1.3.8-beta.3',
  int build = 22,
}) => AppRelease(
  platform: platform,
  arch: 'fixture',
  version: version,
  format: format,
  sha256: 'a' * 64,
  build: build,
  size: 1,
  url: Uri.parse('https://example.com/package'),
);

void main() {
  test('应用内四端下载与发布安装包采用相同版本文件名', () {
    for (final item in [
      (
        'windows',
        'exe',
        'qqbotmanager-windows-v1.3.8-beta.3-build22-setup.exe',
      ),
      ('windows', 'zip', 'qqbotmanager-windows-v1.3.8-beta.3-build22.zip'),
      ('android', 'apk', 'qqbotmanager-android-v1.3.8-beta.3-build22.apk'),
      ('ios', 'ipa', 'qqbotmanager-ios-v1.3.8-beta.3-build22-unsigned.ipa'),
      (
        'macos',
        'dmg',
        'qqbotmanager-macos-v1.3.8-beta.3-build22-universal.dmg',
      ),
    ]) {
      expect(release(item.$1, item.$2).installerFileName, item.$3);
    }
  });
  test('文件名不接受路径注入、非法平台格式和非正构建号', () {
    for (final version in [
      '../x',
      '1.3.8/evil',
      '1.3.8\\evil',
      '1.3.8\nvalue',
    ]) {
      expect(
        () => release('android', 'apk', version: version).installerFileName,
        throwsFormatException,
      );
    }
    expect(
      () => release('android', 'exe').installerFileName,
      throwsFormatException,
    );
    expect(
      () => release('../x', 'apk').installerFileName,
      throwsFormatException,
    );
    expect(
      () => release('android', 'apk', build: 0).installerFileName,
      throwsFormatException,
    );
  });
}
