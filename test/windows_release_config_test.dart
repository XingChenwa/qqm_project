import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows 打包以安装清单为准，不强制要求干净构建中不存在的旧版资源清单', () {
    final script = File('tool/build_windows_release.ps1').readAsStringSync();
    expect(script, contains('install_manifest.txt'));
    expect(
      script,
      contains("if (Test-Path -LiteralPath \$optionalManifest -PathType Leaf)"),
    );
    expect(
      script,
      isNot(
        contains(
          "@('qq_bot_manager.exe','WebView2Loader.dll','native_assets.json')",
        ),
      ),
    );
  });
}
