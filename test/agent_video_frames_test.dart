import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/services/video_frame_service.dart';

void main() {
  test('抽帧页只加载已下载的视频数据，按时间切换画面，拒绝超限输入', () {
    final html = VideoFrameService.sampleHtml(Uint8List.fromList([1, 2, 3]), 6);
    expect(html, contains('media-src data:'));
    expect(html, contains('data:video/mp4;base64,AQID'));
    expect(html, contains('i<6'));
    expect(html, contains('seeked'));
    expect(html, contains('canvas.toDataURL'));
    expect(html, isNot(contains('media-src https:')));
    expect(
      () => VideoFrameService.sampleHtml(Uint8List(1), 1),
      throwsA(isA<AgentException>()),
    );
    expect(
      () => VideoFrameService.sampleHtml(Uint8List(1), 9),
      throwsA(isA<AgentException>()),
    );
  });
  if (const bool.fromEnvironment('QQM_CAPTURE_VIDEO')) {
    test('生成真实动态MP4与抽帧测试页供浏览器验证', () async {
      final folder = Directory('build/agent-video-probe');
      await folder.create(recursive: true);
      final file = File('${folder.path}/motion.mp4');
      final result = await Process.run(
        Platform.environment['QQM_FFMPEG'] ?? 'C:/ffmpeg/bin/ffmpeg.exe',
        [
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=320x180:rate=6:duration=3',
          '-an',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          '-pix_fmt',
          'yuv420p',
          file.absolute.path,
        ],
      );
      expect(result.exitCode, 0, reason: '生成合成测试视频失败');
      await File('${folder.path}/frames.html').writeAsString(
        VideoFrameService.sampleHtml(await file.readAsBytes(), 6),
      );
    });
  }
}
