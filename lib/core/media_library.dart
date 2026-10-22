import 'dart:io';

import '../models/media_image.dart';
import '../services/api_service.dart';
import '../services/material_image_upload.dart';

class MaterialTarget {
  final String appId;
  final int epoch;
  const MaterialTarget(this.appId, this.epoch);
}

typedef MaterialRequester =
    Future<ApiResult<T>> Function<T>(
      MaterialTarget target,
      Future<ApiResult<T>> Function(String token, String baseUrl) action,
    );

/// The platform owns the library; only this bot's current listing and temporary
/// previews live in RAM. Switching bots/credentials discards the entire scope.
class MediaLibrary {
  final ApiService api;
  final MaterialRequester request;
  final String Function() appId;
  final int Function() epoch;
  final void Function() changed;
  MediaLibrary({
    required this.api,
    required this.request,
    required this.appId,
    required this.epoch,
    required this.changed,
  });

  final _images = <BotMediaImage>[];
  final _seenCursors = <String>{};
  String _scope = '', error = '', cursor = '', stage = '', deletingId = '';
  bool loading = false, uploading = false, loaded = false, _disposed = false;
  int total = 0;
  double progress = 0;
  DateTime? _refreshed;
  Future<void>? _loadFuture;
  Future<void>? _resolveFuture;
  bool get busy => loading || uploading || deletingId.isNotEmpty;

  void syncScope() {
    final scope = '${appId()}:${epoch()}';
    if (_scope == scope) return;
    _scope = scope;
    _images.clear();
    _seenCursors.clear();
    _loadFuture = _resolveFuture = null;
    error = cursor = stage = deletingId = '';
    loading = uploading = loaded = false;
    progress = 0;
    total = 0;
    _refreshed = null;
  }

  List<BotMediaImage> get images {
    syncScope();
    return List.unmodifiable(_images);
  }

  MaterialTarget get target => MaterialTarget(appId(), epoch());
  bool isCurrent(MaterialTarget target) =>
      !_disposed && target.appId == appId() && target.epoch == epoch();
  void _notify() {
    if (!_disposed) changed();
  }

  Future<void> refresh({bool more = false}) {
    syncScope();
    if (_loadFuture != null) return _loadFuture!;
    if (uploading || deletingId.isNotEmpty || (more && cursor.isEmpty)) {
      return Future.value();
    }
    final current = target;
    final task = _read(current, more);
    _loadFuture = task;
    return task;
  }

  Future<void> _read(MaterialTarget current, bool more) async {
    loading = true;
    error = '';
    _notify();
    final next = more ? cursor : '';
    try {
      final result = await request(
        current,
        (token, baseUrl) => api.listMediaImages(
          baseUrl: baseUrl,
          accessToken: token,
          cursor: next,
        ),
      );
      if (!isCurrent(current)) return;
      if (!result.isSuccess || result.data == null) {
        error = result.error ?? '素材列表读取失败';
        return;
      }
      final page = result.data!;
      final knownSizes = {for (final image in _images) image.reference: image};
      if (!more) {
        _images.clear();
        _seenCursors.clear();
      }
      final byId = {for (final item in _images) item.id: item};
      for (final item in page.images) {
        final known = knownSizes[item.reference];
        byId[item.id] = known != null && known.width > 0 && known.height > 0
            ? item.withDimensions(known.width, known.height)
            : item;
      }
      _images
        ..clear()
        ..addAll(byId.values.take(100));
      total = page.total;
      loaded = true;
      _refreshed = DateTime.now();
      _seenCursors.add(next);
      cursor = page.cursor;
      if (cursor.isNotEmpty && _seenCursors.contains(cursor)) {
        cursor = '';
        error = '平台分页游标重复，请刷新素材库';
      }
    } catch (_) {
      if (isCurrent(current)) error = '素材列表读取失败，请重试';
    } finally {
      if (isCurrent(current)) {
        loading = false;
        _loadFuture = null;
        _notify();
      }
    }
  }

  Future<BotMediaImage?> upload(File file) async {
    syncScope();
    if (busy) return null;
    final current = target;
    uploading = true;
    error = '';
    stage = '检查图片';
    progress = 0;
    _notify();
    try {
      final image = await MaterialUploadImage.fromFile(file);
      if (!isCurrent(current)) return null;
      final result = await request(
        current,
        (token, baseUrl) => api.uploadMediaImage(
          baseUrl: baseUrl,
          accessToken: token,
          image: image,
          isCurrent: () => isCurrent(current),
          onProgress: (value, percent) {
            if (!isCurrent(current)) return;
            stage = value;
            progress = percent;
            _notify();
          },
        ),
      );
      if (!isCurrent(current)) return null;
      if (!result.isSuccess || result.data == null) {
        error = result.error ?? '素材上传失败';
        return null;
      }
      final uploaded = result.data!;
      final exists = _images.any((image) => image.id == uploaded.id);
      _images.removeWhere((image) => image.id == uploaded.id);
      _images.insert(0, uploaded);
      if (!exists) total++;
      return uploaded;
    } on FormatException catch (e) {
      if (isCurrent(current)) error = e.message.toString();
      return null;
    } catch (_) {
      if (isCurrent(current)) error = '素材上传失败，请检查文件与网络后重试';
      return null;
    } finally {
      if (isCurrent(current)) {
        uploading = false;
        _notify();
      }
    }
  }

  Future<bool> delete(BotMediaImage image) async {
    syncScope();
    if (busy ||
        !_images.any(
          (item) => item.id == image.id && item.reference == image.reference,
        )) {
      return false;
    }
    final current = target;
    deletingId = image.id;
    error = '';
    _notify();
    try {
      final result = await request(
        current,
        (token, baseUrl) => api.deleteMediaImage(
          baseUrl: baseUrl,
          accessToken: token,
          imageId: image.id,
        ),
      );
      if (!isCurrent(current)) return false;
      if (!result.isSuccess && result.errorCode != 40035008) {
        error = result.error ?? '素材删除失败';
        return false;
      }
      _images.removeWhere((item) => item.id == image.id);
      total = (total - 1).clamp(0, 100);
      return true;
    } catch (_) {
      if (isCurrent(current)) error = '素材删除失败，请重试';
      return false;
    } finally {
      if (isCurrent(current)) {
        deletingId = '';
        _notify();
      }
    }
  }

  Future<BotMediaImage?> resolveReference(
    String reference, {
    bool force = false,
  }) async {
    syncScope();
    if (!isMediaReference(reference) || _disposed) return null;
    final current = target;
    BotMediaImage? find() => _images
        .where((i) => i.reference == reference && !i.expired)
        .firstOrNull;
    final fresh =
        _refreshed != null &&
        DateTime.now().difference(_refreshed!) < const Duration(minutes: 5);
    if (!force && fresh && find() != null) return find();
    _resolveFuture ??= _resolvePages(current, refreshFirst: force || !fresh);
    final task = _resolveFuture;
    try {
      await task;
    } finally {
      if (isCurrent(current) && identical(task, _resolveFuture)) {
        _resolveFuture = null;
      }
    }
    return isCurrent(current) ? find() : null;
  }

  /// Include every page when searching, not only the first loaded page.
  /// Concurrent search/preview requests share the same in-memory work.
  Future<void> loadAll() async {
    syncScope();
    final current = target;
    _resolveFuture ??= _resolvePages(current, refreshFirst: false);
    final task = _resolveFuture;
    try {
      await task;
    } finally {
      if (isCurrent(current) && identical(task, _resolveFuture)) {
        _resolveFuture = null;
      }
    }
  }

  Future<void> _resolvePages(
    MaterialTarget current, {
    required bool refreshFirst,
  }) async {
    if (_loadFuture case final pending?) await pending;
    if (!isCurrent(current)) return;
    if (!loaded || refreshFirst) await refresh();
    for (
      var page = 0;
      page < 100 &&
          isCurrent(current) &&
          cursor.isNotEmpty &&
          error.isEmpty &&
          !busy;
      page++
    ) {
      await refresh(more: true);
    }
  }

  void dispose() {
    _disposed = true;
    _images.clear();
  }
}
