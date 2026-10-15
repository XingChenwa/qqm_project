import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// WebView2 does not implement preferredContentMode. Keep its engine version
/// while asking sites for Android content; never rewrite a site's URL to m.*.
String windowsMobileUserAgent(String desktopUserAgent) {
  if (desktopUserAgent.trim().isEmpty) {
    return 'Mozilla/5.0 (Linux; Android 13; Mobile) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Mobile Safari/537.36';
  }
  var agent = desktopUserAgent.replaceFirst(
    RegExp(r'\([^)]*\)'),
    '(Linux; Android 13; Mobile)',
  );
  agent = agent.replaceAll(RegExp(r'\s+Edg/[\d.]+'), '');
  if (!agent.contains('Mobile Safari/')) {
    agent = agent.replaceFirst('Safari/', 'Mobile Safari/');
  }
  return agent;
}

InAppWebViewSettings browserSettings({
  required TargetPlatform platform,
  bool mobile = true,
  String desktopUserAgent = '',
}) => InAppWebViewSettings(
  preferredContentMode: mobile
      ? UserPreferredContentMode.MOBILE
      : UserPreferredContentMode.DESKTOP,
  userAgent: platform == TargetPlatform.windows
      ? (mobile ? windowsMobileUserAgent(desktopUserAgent) : desktopUserAgent)
      : null,
  useWideViewPort: !mobile,
  loadWithOverviewMode: !mobile,
  useShouldOverrideUrlLoading: true,
  supportMultipleWindows: true,
  javaScriptCanOpenWindowsAutomatically: false,
  allowFileAccess: false,
  allowContentAccess: false,
  allowFileAccessFromFileURLs: false,
  allowUniversalAccessFromFileURLs: false,
  isInspectable: false,
);
