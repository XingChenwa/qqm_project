import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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

class AgentImageException extends AgentException {
  final bool cached;
  const AgentImageException(super.message, {this.cached = false});
}

class _AgentImageCacheEntry {
  final String scope;
  final DateTime expires;
  final AgentPreparedImage? image;
  final String? failure;
  const _AgentImageCacheEntry(
    this.scope,
    this.expires, {
    this.image,
    this.failure,
  });
  int get size => image?.bytes.length ?? 0;
}

class AgentImages {
  final AgentHttp http;
  final DateTime Function() now;
  final _cache = <String, _AgentImageCacheEntry>{};
  static const _maxCacheBytes = 16 * 1024 * 1024;
  static const _maxCacheEntries = 64;
  int _cacheBytes = 0;
  AgentImages(this.http, {DateTime Function()? now})
    : now = now ?? DateTime.now;

  /// Memory only. A signed link (including its query) and dimensions form the
  /// key, so a newly supplied URL can immediately replace an expired one.
  void clear({String? scope}) {
    _cache.removeWhere((_, entry) {
      if (scope != null && entry.scope != scope) return false;
      _cacheBytes -= entry.size;
      return true;
    });
  }

  void _remember(String key, _AgentImageCacheEntry entry) {
    _cacheBytes -= _cache.remove(key)?.size ?? 0;
    if (entry.size > _maxCacheBytes) return;
    while (_cache.isNotEmpty &&
        (_cache.length >= _maxCacheEntries ||
            _cacheBytes + entry.size > _maxCacheBytes)) {
      _cacheBytes -= _cache.remove(_cache.keys.first)!.size;
    }
    _cache[key] = entry;
    _cacheBytes += entry.size;
  }

  Future<AgentPreparedImage> prepare(
    Json segment,
    int maxEdge,
    CancelToken cancel, {
    String scope = '',
  }) async {
    if (cancel.isCancelled) throw const AgentException('任务已停止。');
    final ref = _reference(segment);
    final key = sha256
        .convert(utf8.encode(jsonEncode([scope, maxEdge, ref])))
        .toString();
    final time = now();
    _cache.removeWhere((_, entry) {
      if (time.isBefore(entry.expires)) return false;
      _cacheBytes -= entry.size;
      return true;
    });
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      if (cached.image != null) return cached.image!;
      throw AgentImageException(
        '图片此前读取失败，暂缓重复下载：${cached.failure}',
        cached: true,
      );
    }
    try {
      final image = await _prepare(ref, maxEdge, cancel);
      if (cancel.isCancelled) throw const AgentException('任务已停止。');
      _remember(
        key,
        _AgentImageCacheEntry(
          scope,
          now().add(const Duration(minutes: 10)),
          image: image,
        ),
      );
      return image;
    } on AgentException catch (error) {
      // Cancelled requests must not poison another turn's cache.
      if (cancel.isCancelled) throw const AgentException('任务已停止。');
      final invalid =
          error is AgentHttpException &&
          {400, 401, 403, 404, 410}.contains(error.statusCode);
      _remember(
        key,
        _AgentImageCacheEntry(
          scope,
          now().add(
            invalid ? const Duration(minutes: 5) : const Duration(seconds: 30),
          ),
          failure: error.message,
        ),
      );
      throw AgentImageException(error.message);
    }
  }

  String _reference(Json segment) {
    final data = object(segment['data']);
    return text(data['url']).isNotEmpty
        ? text(data['url'])
        : text(data['file']);
  }

  Future<AgentPreparedImage> _prepare(
    String ref,
    int maxEdge,
    CancelToken cancel,
  ) async {
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
      final uri = agentImageUri(ref);
      if (uri == null) {
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

/// QQ image CDNs also emit http links. Upgrade those known public CDNs without
/// making the media reader accept arbitrary cleartext or local service URLs.
Uri? agentImageUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  final host = uri.host.toLowerCase();
  if (uri.scheme == 'http' &&
      (host == 'qpic.cn' ||
          host.endsWith('.qpic.cn') ||
          host == 'qlogo.cn' ||
          host.endsWith('.qlogo.cn'))) {
    return uri.replace(
      scheme: 'https',
      port: uri.hasPort && uri.port != 80 ? uri.port : null,
    );
  }
  return uri.scheme == 'https' ? uri : null;
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
