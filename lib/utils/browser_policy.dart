import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// The Windows plugin's static UA method is absent in some native releases.
/// WebView2 reports its real engine version even in those releases.
String windowsDesktopUserAgent(String browserVersion) {
  final major = RegExp(r'^\d{1,4}(?=\.)').stringMatch(browserVersion.trim());
  return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      '${major == null ? '' : 'Chrome/$major.0.0.0 '}Safari/537.36';
}

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

const blockedExternalSchemes = {
  'javascript',
  'data',
  'file',
  'content',
  'blob',
  'about',
  'filesystem',
  'chrome',
  'chrome-error',
};

/// App links stay out of the page view so the system can open another app.
Uri? externalAppUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http' ||
      scheme == 'https' ||
      blockedExternalSchemes.contains(scheme)) {
    return null;
  }
  if (!RegExp(r'^[a-z][a-z0-9+.-]{0,31}$').hasMatch(scheme)) return null;
  return uri;
}

InAppWebViewSettings browserSettings({
  required TargetPlatform platform,
  bool? mobile,
  String desktopUserAgent = '',
  bool mediaPlayer = false,
}) {
  mobile ??= defaultMobileBrowserMode(platform);
  return InAppWebViewSettings(
    preferredContentMode: mobile
        ? UserPreferredContentMode.MOBILE
        : UserPreferredContentMode.DESKTOP,
    userAgent: platform == TargetPlatform.windows
        ? (mobile ? windowsMobileUserAgent(desktopUserAgent) : desktopUserAgent)
        : null,
    useWideViewPort: !mobile,
    loadWithOverviewMode: !mobile,
    useShouldOverrideUrlLoading: true,
    useOnDownloadStart: true,
    allowsInlineMediaPlayback: mediaPlayer,
    mediaPlaybackRequiresUserGesture: !mediaPlayer,
    supportMultipleWindows: true,
    javaScriptCanOpenWindowsAutomatically: false,
    allowFileAccess: false,
    allowContentAccess: false,
    allowFileAccessFromFileURLs: false,
    allowUniversalAccessFromFileURLs: false,
    isInspectable: false,
  );
}

bool defaultMobileBrowserMode(TargetPlatform platform) =>
    platform == TargetPlatform.android || platform == TargetPlatform.iOS;
