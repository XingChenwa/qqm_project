import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

/// Unlike ordinary rich-media sending, material uploads preserve GIF/WebP
/// bytes and animation. The official material API permits up to 10 MiB.
class MaterialUploadImage {
  static const maxBytes = 10 * 1024 * 1024;
  final Uint8List bytes;
  final String filename, contentType, md5Hex, sha1Hex;
  final int width, height;
  const MaterialUploadImage._(
    this.bytes,
    this.filename,
    this.contentType,
    this.md5Hex,
    this.sha1Hex,
    this.width,
    this.height,
  );

  static Future<MaterialUploadImage> fromFile(File file) async {
    if (!await file.exists()) throw const FormatException('图片不存在，请重新选择');
    if (await file.length() > maxBytes) {
      throw const FormatException('素材图片不能超过 10 MB');
    }
    return fromBytes(await file.readAsBytes(), file.uri.pathSegments.last);
  }

  static Future<MaterialUploadImage> fromBytes(Uint8List bytes, String name) =>
      Isolate.run(() => _prepare(bytes, name));

  static MaterialUploadImage _prepare(Uint8List bytes, String name) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('素材图片为空或超过 10 MB');
    }
    final decoder = img.findDecoderForData(bytes);
    final format = switch (decoder) {
      img.PngDecoder() => ('png', 'image/png'),
      img.JpegDecoder() => ('jpeg', 'image/jpeg'),
      img.GifDecoder() => ('gif', 'image/gif'),
      img.WebPDecoder() => ('webp', 'image/webp'),
      _ => throw const FormatException('素材仅支持 PNG、JPEG、GIF、WebP 图片'),
    };
    final info = decoder!.startDecode(bytes);
    if (info == null || info.width < 1 || info.height < 1) {
      throw const FormatException('图片已损坏或格式无效');
    }
    // Bound native/mobile decoding memory before validating the first frame.
    if (info.width > 8192 ||
        info.height > 8192 ||
        info.width * info.height > 16000000) {
      throw const FormatException('为避免手机内存不足，请将图片缩小到 1600 万像素以内');
    }
    if (decoder.decodeFrame(0) == null) {
      throw const FormatException('图片无法解码，请重新选择');
    }
    var stem = name
        .replaceAll(RegExp(r'\.[^.]*$'), '')
        .replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]'), '_');
    if (stem.isEmpty) stem = 'image';
    stem = stem.substring(0, stem.length.clamp(0, 80));
    return MaterialUploadImage._(
      bytes,
      '$stem.${format.$1}',
      format.$2,
      md5.convert(bytes).toString(),
      sha1.convert(bytes).toString(),
      info.width,
      info.height,
    );
  }
}
