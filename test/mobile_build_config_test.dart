import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';
import 'package:image/image.dart' as img;

void main() {
  test('Android 与 iOS 包名统一为 cn.uuze.botmanager，三端使用自定义图标', () {
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
    expect(wrapper, contains('gradle-8.13-bin.zip'));
  });

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
      androidSteps.any(
        (s) => (s['run']?.toString() ?? '').startsWith(
          'flutter build apk --debug --no-pub ',
        ),
      ),
      isTrue,
    );
    expect(
      iosSteps.any((s) => s['run'] == 'bash scripts/build_unsigned_ipa.sh'),
      isTrue,
    );
    expect(androidSteps.last['with']['path'], endsWith('app-debug.apk'));
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
