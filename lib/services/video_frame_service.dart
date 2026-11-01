import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../agent/models.dart';
import '../agent/videos.dart';

/// Decode bounded, already-downloaded bytes in an isolated native view. The
/// page can load data media only; it cannot follow redirects or open websites.
class VideoFrameService {
  static final shared = VideoFrameService();
  Future<void> _queue = Future.value();

  Future<AgentVideoSample> extract(
    Uint8List bytes,
    int count,
    CancelToken cancel,
  ) async {
    final previous = _queue, done = Completer<void>();
    _queue = done.future;
    await previous;
    try {
      if (cancel.isCancelled) throw const AgentException('任务已停止。');
      return await _native(bytes, count, cancel);
    } finally {
      done.complete();
    }
  }

  Future<AgentVideoSample> _native(
    Uint8List bytes,
    int count,
    CancelToken cancel,
  ) async {
    if (kIsWeb ||
        !(Platform.isWindows ||
            Platform.isAndroid ||
            Platform.isIOS ||
            Platform.isMacOS) ||
        InAppWebViewPlatform.instance == null) {
      throw const AgentException('当前平台没有视频抽帧服务，请在预设中选择支持原生视频输入的模型。');
    }
    final html = sampleHtml(bytes, count);
    WebViewEnvironment? environment;
    HeadlessInAppWebView? view;
    Future<void>? starting;
    var started = false, disposed = false;
    final complete = Completer<AgentVideoSample>(),
        frames = <AgentVideoFrame>[];
    void fail(String message) {
      if (!disposed && !complete.isCompleted) {
        complete.completeError(AgentException(message));
      }
    }

    // Observe early errors even when the native view is still being created.
    unawaited(
      complete.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    unawaited(cancel.whenCancel.then((_) => fail('任务已停止。')));
    try {
      if (Platform.isWindows) {
        final support = await getApplicationSupportDirectory().timeout(
          const Duration(seconds: 3),
        );
        environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: p.join(support.path, 'video-analysis'),
          ),
        ).timeout(const Duration(seconds: 5));
      }
      view = HeadlessInAppWebView(
        webViewEnvironment: environment,
        initialSize: const Size(640, 360),
        initialData: InAppWebViewInitialData(
          data: html,
          baseUrl: WebUri('https://qqm-video.invalid/'),
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
            handlerName: 'qqmVideoFrame',
            callback: (args) {
              if (disposed ||
                  complete.isCompleted ||
                  cancel.isCancelled ||
                  args.isEmpty) {
                return null;
              }
              final data = object(args.first), encoded = text(data['dataUrl']);
              final at = double.tryParse(text(data['seconds']));
              if (frames.length >= count ||
                  encoded.length > 2 * 1024 * 1024 ||
                  !encoded.startsWith('data:image/jpeg;base64,') ||
                  at == null ||
                  !at.isFinite ||
                  at < 0) {
                fail('视频抽帧数据无效或过大。');
                return null;
              }
              try {
                frames.add(
                  AgentVideoFrame(
                    at,
                    base64Decode(encoded.substring(encoded.indexOf(',') + 1)),
                  ),
                );
              } catch (_) {
                fail('视频抽帧编码无效。');
              }
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: 'qqmVideoDone',
            callback: (args) {
              if (!disposed && !complete.isCompleted && args.isNotEmpty) {
                final duration = double.tryParse(
                  text(object(args.first)['duration']),
                );
                if (duration == null ||
                    !duration.isFinite ||
                    duration <= 0 ||
                    duration > 600 ||
                    frames.length != count) {
                  fail('视频抽帧未完整完成。');
                } else {
                  complete.complete(
                    AgentVideoSample(duration, List.unmodifiable(frames)),
                  );
                }
              }
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: 'qqmVideoError',
            callback: (_) {
              fail('视频解码失败或不支持当前格式，请改用原生视频模型。');
              return null;
            },
          );
        },
      );
      starting = view.run();
      await starting.timeout(const Duration(seconds: 10));
      started = true;
      return await complete.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw const AgentException('视频抽帧超时，未生成分析结果。'),
      );
    } on AgentException {
      rethrow;
    } catch (_) {
      throw const AgentException('视频抽帧服务不可用，请检查系统WebView或使用原生视频模型。');
    } finally {
      disposed = true;
      final pending = starting,
          webView = view,
          browserEnvironment = environment;
      Future<void> release() async {
        try {
          if (pending != null) await pending;
          await webView?.dispose();
        } catch (_) {}
        try {
          await browserEnvironment?.dispose();
        } catch (_) {}
      }

      if (started) {
        await release().timeout(const Duration(seconds: 2), onTimeout: () {});
      } else {
        unawaited(release());
      }
    }
  }

  @visibleForTesting
  static String sampleHtml(Uint8List bytes, int count) {
    if (bytes.isEmpty ||
        bytes.length > AgentVideos.maxDownloadBytes ||
        count < 2 ||
        count > 8) {
      throw const AgentException('视频大小或抽帧数量超出范围。');
    }
    final webm =
        bytes.length >= 4 &&
        bytes[0] == 0x1a &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xdf &&
        bytes[3] == 0xa3;
    final data =
        'data:video/${webm ? 'webm' : 'mp4'};base64,${base64Encode(bytes)}';
    return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<style>html,body{margin:0;overflow:hidden}video{width:640px;height:360px;object-fit:contain}</style>
</head><body><video id="v" muted playsinline webkit-playsinline preload="auto" src="$data"></video>
<script>
const v=document.getElementById('v');let started=false;
function host(name,value){return window.flutter_inappwebview.callHandler(name,value);}
function seek(t){return new Promise((resolve,reject)=>{let timer;const end=()=>{clearTimeout(timer);v.removeEventListener('seeked',end);resolve();};timer=setTimeout(()=>{v.removeEventListener('seeked',end);reject(Error('seek timeout'));},8000);if(Math.abs(v.currentTime-t)<0.001){end();return;}v.addEventListener('seeked',end,{once:true});v.currentTime=t;});}
async function start(){if(started||v.readyState<2||!window.flutter_inappwebview?.callHandler)return;started=true;
try{if(!Number.isFinite(v.duration)||v.duration<=0||v.duration>600||!v.videoWidth||!v.videoHeight)throw Error('invalid video');
const canvas=document.createElement('canvas'),scale=Math.min(1,960/v.videoWidth,960/v.videoHeight);canvas.width=Math.max(1,Math.round(v.videoWidth*scale));canvas.height=Math.max(1,Math.round(v.videoHeight*scale));const ctx=canvas.getContext('2d');
for(let i=0;i<$count;i++){await seek(Math.min(v.duration-0.001,v.duration*(i+0.5)/$count));await new Promise(r=>{const timer=setTimeout(r,100);requestAnimationFrame(()=>requestAnimationFrame(()=>{clearTimeout(timer);r();}));});ctx.drawImage(v,0,0,canvas.width,canvas.height);await host('qqmVideoFrame',{seconds:v.currentTime,dataUrl:canvas.toDataURL('image/jpeg',0.8)});}
await host('qqmVideoDone',{duration:v.duration});}catch(_){await host('qqmVideoError',{});}}
v.addEventListener('loadeddata',start);v.addEventListener('error',()=>{if(window.flutter_inappwebview?.callHandler)host('qqmVideoError',{});});window.addEventListener('flutterInAppWebViewPlatformReady',start);start();
</script></body></html>''';
  }
}
