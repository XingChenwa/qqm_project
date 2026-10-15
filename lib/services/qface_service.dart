import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/qq_face.dart';

/// Public, unauthenticated catalog. Never use the QQ API client's headers.
class QFaceService {
  static const endpoint =
      'https://koishi.js.org/QFace/assets/qq_emoji/_index.json';
  static final shared = QFaceService();
  static const maxBytes = 2 * 1024 * 1024;
  final Dio _dio;
  QFaceCatalog? _cached;
  DateTime? _checkedAt;
  Future<QFaceCatalog>? _pending;

  QFaceService({HttpClientAdapter? adapter})
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 5),
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {'Accept': 'application/json'},
        ),
      ) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  Future<QFaceCatalog> getCatalog() {
    final cached = _cached;
    if (cached != null &&
        _checkedAt != null &&
        DateTime.now().difference(_checkedAt!) <
            (cached.isEmpty
                ? const Duration(minutes: 5)
                : const Duration(hours: 24))) {
      return Future.value(cached);
    }
    return _pending ??= _load()
        .then((catalog) {
          _cached = catalog;
          _checkedAt = DateTime.now();
          return catalog;
        })
        .whenComplete(() => _pending = null);
  }

  Future<QFaceCatalog> _load() async {
    final cancel = CancelToken();
    try {
      return await _request(cancel).timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          cancel.cancel('QFace 索引查询超时');
          return const QFaceCatalog.empty();
        },
      );
    } catch (_) {
      return const QFaceCatalog.empty();
    }
  }

  Future<QFaceCatalog> _request(CancelToken cancel) async {
    final response = await _dio.get<ResponseBody>(
      endpoint,
      cancelToken: cancel,
      options: Options(responseType: ResponseType.stream),
    );
    if (response.statusCode != 200 || response.data == null) {
      return const QFaceCatalog.empty();
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      if (bytes.length + chunk.length > maxBytes) {
        cancel.cancel('QFace 索引过大');
        return const QFaceCatalog.empty();
      }
      bytes.add(chunk);
    }
    return QFaceCatalog.fromJson(jsonDecode(utf8.decode(bytes.takeBytes())));
  }

  void dispose() => _dio.close(force: true);
}
