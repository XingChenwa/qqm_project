import 'package:flutter/foundation.dart';

bool get isDesktopPlatform =>
    !kIsWeb &&
    const {
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform);
bool get isMobilePlatform =>
    !kIsWeb &&
    const {
      TargetPlatform.android,
      TargetPlatform.iOS,
    }.contains(defaultTargetPlatform);
