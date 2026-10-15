import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';
import 'package:image/image.dart' as img;

void main() {
  test('Android、iOS、macOS 包名统一并使用自定义图标', () {
    final app = File('android/app/build.gradle.kts').readAsStringSync();
    expect(app, contains('namespace = "cn.uuze.botmanager"'));
    expect(app, contains('applicationId = "cn.uuze.botmanager"'));
    expect(
      File(
        'android/app/src/main/kotlin/cn/uuze/botmanager/MainActivity.kt',
      ).readAsStringSync(),
      startsWith('package cn.uuze.botmanager'),
    );
    final ios = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(
      RegExp(
        r'PRODUCT_BUNDLE_IDENTIFIER = cn\.uuze\.botmanager;',
      ).allMatches(ios).length,
      3,
    );
    expect(ios, isNot(contains('com.qqbot.qqBotManager')));
    final icon = img.decodePng(
      File(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png',
      ).readAsBytesSync(),
    )!;
    expect(icon.width, 1024);
    expect(icon.height, 1024);
    expect(icon.numChannels, 3);
    final android = img.decodePng(
      File(
        'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
      ).readAsBytesSync(),
    )!;
    expect(android.width, 192);
    expect(
      File('windows/runner/resources/app_icon.ico').lengthSync(),
      greaterThan(1024),
    );
    expect(File('assets/branding/logo.png').existsSync(), isTrue);
    expect(
      File('macos/Runner/Configs/AppInfo.xcconfig').readAsStringSync(),
      contains('PRODUCT_BUNDLE_IDENTIFIER = cn.uuze.botmanager'),
    );
    for (final name in ['DebugProfile', 'Release']) {
      final entitlements = File(
        'macos/Runner/$name.entitlements',
      ).readAsStringSync();
      expect(entitlements, contains('com.apple.security.network.client'));
      expect(
        entitlements,
        contains('com.apple.security.files.user-selected.read-write'),
      );
    }
  });
  test('安卓工具链固定兼容的 AGP/Gradle，并显式编译应用和文件选择插件的 Kotlin', () {
    final settings = File('android/settings.gradle.kts').readAsStringSync();
    final app = File('android/app/build.gradle.kts').readAsStringSync();
    final wrapper = File(
      'android/gradle/wrapper/gradle-wrapper.properties',
    ).readAsStringSync();
    expect(
      settings,
      contains('id("com.android.application") version "8.13.2"'),
    );
    expect(
      settings,
      contains('id("org.jetbrains.kotlin.android") version "2.3.20"'),
    );
    expect(app, contains('id("org.jetbrains.kotlin.android")'));
    expect(app, contains('enableV1Signing = true'));
    expect(app, contains('enableV2Signing = true'));
    expect(app, contains('enableV3Signing = true'));
    expect(wrapper, contains('gradle-8.13-bin.zip'));
  });

  test('移动构建工作流只手动触发，安卓使用固定签名正式包且不需要 Apple 私钥', () {
    final workflow =
        loadYaml(File('.github/workflows/mobile-build.yml').readAsStringSync())
            as YamlMap;
    expect((workflow['on'] as YamlMap).keys.toList(), ['workflow_dispatch']);
    expect(workflow['permissions']['contents'], 'read');
    expect(workflow['jobs']['android']['runs-on'], 'ubuntu-24.04');
    expect(workflow['jobs']['ios']['runs-on'], 'macos-15');
    expect(workflow['jobs']['macos']['runs-on'], 'macos-15');
    expect(
      (workflow['jobs']['macos']['steps'] as YamlList).any(
        (s) => s['run'] == 'bash scripts/build_macos_package.sh',
      ),
      isTrue,
    );
    final androidSteps = workflow['jobs']['android']['steps'] as YamlList;
    final iosSteps = workflow['jobs']['ios']['steps'] as YamlList;
    expect(
      androidSteps.any(
        (s) => (s['run']?.toString() ?? '').contains('android/key.properties'),
      ),
      isTrue,
    );
    expect(
      androidSteps.any(
        (s) => (s['run']?.toString() ?? '').startsWith(
          'flutter build apk --release --no-pub ',
        ),
      ),
      isTrue,
    );
    expect(
      iosSteps.any((s) => s['run'] == 'bash scripts/build_unsigned_ipa.sh'),
      isTrue,
    );
    expect(androidSteps.last['with']['path'], endsWith('app-release.apk'));
    expect(iosSteps.last['with']['path'], 'dist/qq_bot_manager-unsigned.ipa');
    expect(
      workflow['env']['UPDATE_PUBLIC_KEY'],
      contains('vars.UPDATE_PUBLIC_KEY'),
    );
    final apkBuild = androidSteps
        .firstWhere(
          (s) => (s['run']?.toString() ?? '').startsWith('flutter build apk '),
        )['run']
        .toString();
    expect(apkBuild, contains('--dart-define="UPDATE_PUBLIC_KEY='));
    expect(apkBuild, contains('--dart-define="UPDATE_BASE_URL='));
    final source = File(
      '.github/workflows/mobile-build.yml',
    ).readAsStringSync();
    expect(source, contains('secrets.ANDROID_KEYSTORE_BASE64'));
    expect(source, contains('secrets.ANDROID_KEYSTORE_PASSWORD'));
    expect(source, contains('secrets.ANDROID_KEY_ALIAS'));
    expect(source, isNot(contains('APPLE_')));
    expect(source, isNot(contains('.p12')));
    expect(source, isNot(contains('PROVISIONING_PROFILE')));
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
  test('macOS 校验主程序及原生库双架构，lipo 输入文件位于校验参数之前', () {
    final script = File('scripts/build_macos_package.sh').readAsStringSync();
    expect(script, contains('lipo "\$binary" -verify_arch arm64 x86_64'));
    expect(script, contains('lipo "\$candidate" -verify_arch arm64 x86_64'));
    expect(script, contains('codesign --verify --deep --strict'));
    expect(script, contains('hdiutil verify'));
  });
}
