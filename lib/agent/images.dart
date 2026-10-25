import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:image/image.dart' as img;

import 'http.dart';
import 'models.dart';
import 'web.dart';

class AgentPreparedImage {
  final Uint8List bytes;
  final int width, height;
  const AgentPreparedImage(this.bytes, this.width, this.height);
  String get dataUrl => 'data:image/jpeg;base64,${base64Encode(bytes)}';
}

class AgentImages {
  final AgentHttp http;
  AgentImages(this.http);
  Future<AgentPreparedImage> prepare(
    Json segment,
    int maxEdge,
    CancelToken cancel,
  ) async {
    final data = object(segment['data']);
    final ref = text(data['url']).isNotEmpty
        ? text(data['url'])
        : text(data['file']);
    Uint8List bytes;
    if (ref.startsWith('base64://') || ref.startsWith('data:image/')) {
      final encoded = ref.startsWith('base64://')
          ? ref.substring(9)
          : ref.substring(ref.indexOf(',') + 1);
      if (encoded.length > 7 * 1024 * 1024) {
        throw const AgentException('图片超过 5 MB。');
      }
      try {
        bytes = base64Decode(encoded);
      } catch (_) {
        throw const AgentException('图片编码无效。');
      }
    } else {
      final uri = Uri.tryParse(ref);
      if (uri == null || uri.scheme != 'https') {
        throw const AgentException('图片未提供可用的公共 HTTPS 地址。');
      }
      bytes = (await agentPublicGet(
        http,
        uri,
        cancel: cancel,
        maxBytes: 5 * 1024 * 1024,
      )).bytes;
    }
    if (cancel.isCancelled) throw const AgentException('任务已停止。');
    final result = await Isolate.run(() => resizeAgentImage(bytes, maxEdge));
    if (cancel.isCancelled) throw const AgentException('任务已停止。');
    return result;
  }
}

/// Decode one frame in a worker isolate, check dimensions BEFORE allocating
/// pixels, orient, downsize without enlarging, and strip metadata via re-encode.
AgentPreparedImage resizeAgentImage(Uint8List bytes, int maxEdge) {
  if (maxEdge < 256 || maxEdge > 4096) {
    throw const AgentException('输入图片最大边长须为 256–4096 像素。');
  }
  if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
    throw const AgentException('图片为空或超过 5 MB。');
  }
  try {
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null || info.width < 1 || info.height < 1) {
      throw const AgentException('图片格式无效。');
    }
    if (info.width > 8192 ||
        info.height > 8192 ||
        info.width * info.height > 16000000) {
      throw const AgentException('图片超过 1600 万像素或单边 8192 像素，请先压缩。');
    }
    final frame = decoder!.decodeFrame(0);
    if (frame == null) throw const AgentException('图片解码失败。');
    var image = img.bakeOrientation(frame);
    final edge = image.width > image.height ? image.width : image.height;
    if (edge > maxEdge) {
      image = img.copyResize(
        image,
        width: (image.width * maxEdge / edge).round().clamp(1, maxEdge),
        height: (image.height * maxEdge / edge).round().clamp(1, maxEdge),
        interpolation: img.Interpolation.average,
      );
    }
    // JPEG on a white canvas handles transparency consistently across providers.
    final canvas = img.Image(
      width: image.width,
      height: image.height,
      numChannels: 3,
    );
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(canvas, image);
    final encoded = img.encodeJpg(canvas, quality: 85);
    if (encoded.length > 5 * 1024 * 1024) {
      throw const AgentException('图片处理后仍过大，请调低输入图片最大边长。');
    }
    return AgentPreparedImage(encoded, canvas.width, canvas.height);
  } on AgentException {
    rethrow;
  } catch (_) {
    throw const AgentException('图片损坏或暂不支持此格式。');
  }
}
