import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:image/image.dart' as img;

class PreparedImage {
  final Uint8List bytes;
  final String filename;
  const PreparedImage(this.bytes, this.filename);
}

/// Never reuse the authenticated QQ client for third-party image requests.
class ImageUploadService {
  static const maxBytes = 5 * 1024 * 1024;
  final Dio? downloadClient;
  const ImageUploadService({this.downloadClient});

  Future<PreparedImage> fromFile(File file) async {
    if (!await file.exists()) throw const FormatException('本地图片不存在，请重新选择');
    if (await file.length() > maxBytes) {
      throw const FormatException('图片直传不能超过 5 MB，请先压缩图片');
    }
    return prepare(await file.readAsBytes(), file.uri.pathSegments.last);
  }

  Future<PreparedImage> fromUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('请输入有效的图片 HTTP / HTTPS 地址');
    }
    final dio =
        downloadClient ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 20),
            maxRedirects: 5,
          ),
        );
    final cancel = CancelToken();
    final deadline = Timer(
      const Duration(seconds: 30),
      () => cancel.cancel('图片下载超时'),
    );
    try {
      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Accept': 'image/*', 'User-Agent': 'QQBotManager/1.2'},
        ),
      );
      if (response.statusCode != 200 || response.data == null) {
        throw const FormatException('表情图片下载失败，请换一张重试');
      }
      final length = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (length != null && length > maxBytes) {
        cancel.cancel('图片过大');
        throw const FormatException('表情图片超过 5 MB，请压缩后发送');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream) {
        if (builder.length + chunk.length > maxBytes) {
          cancel.cancel('图片过大');
          throw const FormatException('表情图片超过 5 MB，请压缩后发送');
        }
        builder.add(chunk);
      }
      return await prepare(
        builder.takeBytes(),
        uri.pathSegments.isEmpty ? 'emoji' : uri.pathSegments.last,
      );
    } finally {
      deadline.cancel();
      if (downloadClient == null) dio.close(force: true);
    }
  }

  Future<PreparedImage> prepare(Uint8List bytes, String filename) =>
      Isolate.run(() => _normalizeImage(bytes, filename));
}

PreparedImage _normalizeImage(Uint8List bytes, String filename) {
  if (bytes.isEmpty || bytes.length > ImageUploadService.maxBytes) {
    throw const FormatException('图片为空或超过 5 MB');
  }
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width < 1 || info.height < 1) {
    throw const FormatException('表情链接返回的不是有效图片，可能是网页、错误页或已失效链接');
  }
  if (info.width > 8192 ||
      info.height > 8192 ||
      info.width * info.height > 16000000) {
    throw const FormatException('图片分辨率过大，请先缩小到 1600 万像素以内');
  }
  final frame = decoder!.decodeFrame(0);
  if (frame == null) throw const FormatException('图片损坏或格式不支持，请重新选择');
  final png = decoder is img.PngDecoder;
  final jpeg = decoder is img.JpegDecoder;
  final stem = filename
      .replaceAll(RegExp(r'\.[^.]*$'), '')
      .replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]'), '_');
  final safeName = stem.isEmpty
      ? 'emoji'
      : stem.substring(0, stem.length.clamp(0, 80));
  if (png || jpeg) {
    return PreparedImage(bytes, '$safeName.${png ? 'png' : 'jpg'}');
  }
  // QQ's documented image types are PNG/JPG. GIF/WebP use their first frame.
  final converted = img.encodePng(frame);
  if (converted.length > ImageUploadService.maxBytes) {
    throw const FormatException('表情转为静态 PNG 后超过 5 MB，请先缩小图片');
  }
  return PreparedImage(converted, '$safeName.png');
}
