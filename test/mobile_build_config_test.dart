import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('移动构建工作流只手动触发，两个平台保存正确产物且不需要 Apple 私钥', () {
    final workflow =
        loadYaml(File('.github/workflows/mobile-build.yml').readAsStringSync())
            as YamlMap;
    expect((workflow['on'] as YamlMap).keys.toList(), ['workflow_dispatch']);
    expect(workflow['permissions']['contents'], 'read');
    expect(workflow['jobs']['android']['runs-on'], 'ubuntu-24.04');
    expect(workflow['jobs']['ios']['runs-on'], 'macos-15');
    final androidSteps = workflow['jobs']['android']['steps'] as YamlList;
    final iosSteps = workflow['jobs']['ios']['steps'] as YamlList;
    expect(
      androidSteps.any((s) => s['run'] == 'flutter build apk --debug --no-pub'),
      isTrue,
    );
    expect(
      iosSteps.any((s) => s['run'] == 'bash scripts/build_unsigned_ipa.sh'),
      isTrue,
    );
    expect(androidSteps.last['with']['path'], endsWith('app-debug.apk'));
    expect(iosSteps.last['with']['path'], 'dist/qq_bot_manager-unsigned.ipa');
    expect(
      File('.github/workflows/mobile-build.yml').readAsStringSync(),
      isNot(contains('secrets.')),
    );
  });

  test('IPA 打包必须先编译 iPhone 真机应用并验证 arm64，不会将源代码改名充当安装包', () {
    final script = File('scripts/build_unsigned_ipa.sh').readAsStringSync();
    expect(
      script,
      contains('flutter build ios --release --no-codesign --no-pub'),
    );
    expect(script, contains('build/ios/iphoneos/Runner.app'));
    expect(script, contains('lipo -archs'));
    expect(script, contains('grep -q arm64'));
    expect(script, contains('Payload/Runner.app'));
    expect(script, isNot(contains('\r')));
  });
}
