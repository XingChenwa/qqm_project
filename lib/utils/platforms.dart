import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

bool usePhoneLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width < 700 || (isMobilePlatform && size.shortestSide < 600);
}

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
