import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/media_link.dart';

typedef VideoThumbnailExtractor = Future<Uint8List?> Function(Uri source);

/// A single offscreen native view captures the first decoded frame, without
/// autoplaying sound or downloading the whole video into the chat database.
/// Only small thumbnail bytes are retained in a bounded, in-memory LRU cache.
class VideoThumbnailService {
  static final shared = VideoThumbnailService();
  static const maximumThumbnailBytes = 2 * 1024 * 1024;
  final VideoThumbnailExtractor _extract;
  final int cacheSize;
  final _cache = <String, Uint8List?>{};
  final _pending = <String, Future<Uint8List?>>{};
  Future<void> _queue = Future<void>.value();

  VideoThumbnailService({VideoThumbnailExtractor? extract, this.cacheSize = 24})
    : _extract = extract ?? _nativeThumbnail;

  Future<Uint8List?> load(String source) {
    final uri = mediaHttpUri(source);
    if (uri == null) return Future<Uint8List?>.value();
    final key = uri.toString();
    if (_cache.containsKey(key)) {
      final cached = _cache.remove(key);
      _cache[key] = cached;
      return Future<Uint8List?>.value(cached);
    }
    return _pending[key] ??= _schedule(key, uri);
  }

  Future<Uint8List?> _schedule(String key, Uri uri) async {
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    await previous;
    try {
      Uint8List? bytes;
      try {
        bytes = await _extract(uri);
        if (bytes != null &&
            (bytes.isEmpty || bytes.length > maximumThumbnailBytes)) {
          bytes = null;
        }
      } catch (_) {
        // A cover is optional. Never disclose signed media URLs in diagnostics.
      }
      _cache[key] = bytes;
      while (_cache.length > cacheSize.clamp(1, 100)) {
        _cache.remove(_cache.keys.first);
      }
      return bytes;
    } finally {
      _pending.remove(key);
      done.complete();
    }
  }

  static Future<Uint8List?> _nativeThumbnail(Uri uri) async {
    if (kIsWeb ||
        !(Platform.isWindows ||
            Platform.isAndroid ||
            Platform.isIOS ||
            Platform.isMacOS) ||
        InAppWebViewPlatform.instance == null) {
      return null;
    }
    WebViewEnvironment? environment;
    HeadlessInAppWebView? view;
    Future<void>? starting;
    var started = false;
    try {
      if (Platform.isWindows) {
        if (await WebViewEnvironment.getAvailableVersion().timeout(
              const Duration(seconds: 3),
            ) ==
            null) {
          return null;
        }
        final support = await getApplicationSupportDirectory().timeout(
          const Duration(seconds: 3),
        );
        environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: p.join(support.path, 'video-covers'),
          ),
        );
      }
      final frame = Completer<void>();
      view = HeadlessInAppWebView(
        webViewEnvironment: environment,
        initialSize: const Size(360, 204),
        initialData: InAppWebViewInitialData(
          data: thumbnailHtml(uri),
          baseUrl: WebUri('${uri.scheme}://qqm-thumbnail.invalid/'),
        ),
        initialSettings: InAppWebViewSettings(
          mediaPlaybackRequiresUserGesture: true,
          allowsInlineMediaPlayback: true,
          allowFileAccess: false,
          allowContentAccess: false,
          allowFileAccessFromFileURLs: false,
          allowUniversalAccessFromFileURLs: false,
          supportMultipleWindows: false,
          javaScriptCanOpenWindowsAutomatically: false,
          isInspectable: false,
        ),
        onWebViewCreated: (controller) {
          controller.addJavaScriptHandler(
            handlerName: 'qqmThumbnailReady',
            callback: (_) {
              if (!frame.isCompleted) frame.complete();
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: 'qqmThumbnailError',
            callback: (_) {
              if (!frame.isCompleted) frame.complete();
              return null;
            },
          );
        },
      );
      starting = view.run();
      await starting.timeout(const Duration(seconds: 8));
      started = true;
      await frame.future.timeout(const Duration(seconds: 10));
      final controller = view.webViewController;
      final decoded = await controller
          ?.evaluateJavascript(
            source:
                "(function(){var v=document.querySelector('video');"
                'if(!v||v.readyState<2||!v.videoWidth||v.error)return null;'
                'var r=v.getBoundingClientRect(),s=Math.min('
                'r.width/v.videoWidth,r.height/v.videoHeight);'
                'var w=v.videoWidth*s,h=v.videoHeight*s;'
                'return {x:r.left+(r.width-w)/2,y:r.top+(r.height-h)/2,width:w,height:h};})()',
          )
          .timeout(const Duration(seconds: 2));
      if (decoded is! Map ||
          !['x', 'y', 'width', 'height'].every((k) => decoded[k] is num) ||
          (decoded['width'] as num) <= 0 ||
          (decoded['height'] as num) <= 0) {
        return null;
      }
      // Give the native compositor a frame after the decoded-frame event.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return await controller
          ?.takeScreenshot(
            screenshotConfiguration: ScreenshotConfiguration(
              compressFormat: CompressFormat.JPEG,
              quality: 75,
              rect: InAppWebViewRect(
                x: (decoded['x'] as num).toDouble().clamp(0, double.infinity),
                y: (decoded['y'] as num).toDouble().clamp(0, double.infinity),
                width: (decoded['width'] as num).toDouble(),
                height: (decoded['height'] as num).toDouble(),
              ),
            ),
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    } finally {
      final pending = starting;
      final webView = view;
      final browserEnvironment = environment;
      Future<void> release() async {
        try {
          if (pending != null) await pending;
          await webView?.dispose();
        } catch (_) {
          // No bot credentials are used by this display-only view.
        }
        try {
          await browserEnvironment?.dispose();
        } catch (_) {}
      }

      // A late platform creation must still be disposed after a timeout.
      if (started) {
        await release().timeout(const Duration(seconds: 2), onTimeout: () {});
      } else {
        unawaited(release());
      }
    }
  }

  @visibleForTesting
  static String thumbnailHtml(Uri uri) {
    if (mediaHttpUri(uri.toString()) == null) {
      throw const FormatException('视频地址无效');
    }
    final source = const HtmlEscape(HtmlEscapeMode.attribute).convert('$uri');
    return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src https: http:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<style>html,body{margin:0;width:100%;height:100%;background:#17233b;overflow:hidden}
video{width:100%;height:100%;object-fit:contain}</style></head>
<body><video muted playsinline webkit-playsinline preload="auto" src="$source"></video>
<script>var v=document.querySelector('video'),ready=false;
function notify(){if(window.flutter_inappwebview){
 window.flutter_inappwebview.callHandler(v.error?'qqmThumbnailError':'qqmThumbnailReady');}}
v.addEventListener('loadeddata',function(){ready=true;v.pause();notify();});
v.addEventListener('error',notify);
window.addEventListener('flutterInAppWebViewPlatformReady',function(){
 if(ready||v.error)notify();});</script></body></html>''';
  }
}
