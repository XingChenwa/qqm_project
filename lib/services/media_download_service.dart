import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../utils/media_link.dart';

class PreparedDownload {
  final Directory directory;
  final File file;
  final String filename, mime;
  final int size;
  PreparedDownload(
    this.directory,
    this.file,
    this.filename,
    this.mime,
    this.size,
  );
  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Standalone unauthenticated transport. Downloads never use the QQ API client,
/// execute files, or derive filesystem paths from a response header.
class MediaDownloadService {
  final Dio _http;
  final int maxBytes;
  final Future<Directory> Function() temporaryDirectory;
  MediaDownloadService({
    Dio? http,
    int? maxBytes,
    Future<Directory> Function()? temporaryDirectory,
  }) : _http =
           http ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 30),
               followRedirects: false,
             ),
           ),
       maxBytes =
           maxBytes ??
           ((Platform.isAndroid || Platform.isIOS) ? 64 : 512) * 1024 * 1024,
       temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  Future<PreparedDownload> download(
    String url,
    CancelToken cancel, {
    String? suggestedFilename,
    void Function(int received, int? total)? onProgress,
  }) async {
    var uri = mediaHttpUri(url);
    if (uri == null) throw const FormatException('仅支持 HTTP / HTTPS 文件下载');
    Directory? directory;
    IOSink? sink;
    final deadline = Timer(
      const Duration(minutes: 10),
      () => cancel.cancel('下载超时'),
    );
    try {
      Response<ResponseBody>? response;
      for (var hop = 0; hop < 6; hop++) {
        response = await _http.getUri<ResponseBody>(
          uri!,
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
            headers: {'Accept': '*/*'},
            validateStatus: (_) => true,
          ),
        );
        if (response.statusCode == 200) break;
        await response.data?.stream.listen((_) {}).cancel();
        if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) {
          throw FormatException(
            '文件下载返回 HTTP ${response.statusCode}，链接可能过期或需要重新获取',
          );
        }
        final location = response.headers.value('location');
        final next = location == null
            ? null
            : mediaHttpUri(uri.resolve(location).toString());
        if (next == null || (uri.scheme == 'https' && next.scheme != 'https')) {
          throw const FormatException('下载链接跳转无效或试图降低传输安全性');
        }
        uri = next;
      }
      if (response?.statusCode != 200 || response?.data == null) {
        throw const FormatException('文件下载跳转过多或未返回内容');
      }
      final body = response!.data!;
      final total = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if ((total ?? 0) > maxBytes) {
        await body.stream.listen((_) {}).cancel();
        throw FormatException(
          '文件超过当前设备 ${maxBytes ~/ (1024 * 1024)} MB 的安全下载上限',
        );
      }
      final mime =
          response.headers.value('content-type') ?? 'application/octet-stream';
      final filename = safeDownloadName(
        suggestedFilename,
        uri!,
        mime: mime,
        disposition: response.headers.value('content-disposition') ?? '',
      );
      directory = await (await temporaryDirectory()).createTemp(
        'qqm-download-',
      );
      final file = File(p.join(directory.path, 'payload'));
      sink = file.openWrite();
      var received = 0;
      var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
      await sink.addStream(
        body.stream.map((chunk) {
          if (cancel.isCancelled) throw const FormatException('下载已取消');
          received += chunk.length;
          if (received > maxBytes) {
            throw FormatException('文件超过 ${maxBytes ~/ (1024 * 1024)} MB 下载上限');
          }
          final now = DateTime.now();
          if (now.difference(lastProgress).inMilliseconds >= 150) {
            onProgress?.call(received, total);
            lastProgress = now;
          }
          return chunk;
        }),
      );
      await sink.flush();
      await sink.close();
      sink = null;
      if (cancel.isCancelled) throw const FormatException('下载已取消');
      if (received == 0 || (total != null && total != received)) {
        throw const FormatException('文件下载不完整，请重新获取链接后重试');
      }
      onProgress?.call(received, total);
      return PreparedDownload(directory, file, filename, mime, received);
    } catch (_) {
      // addStream can already close a failed sink. Cleanup must not replace
      // the original size/cancellation error or skip removing the partial file.
      try { await sink?.close(); } catch (_) {}
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
      rethrow;
    } finally {
      deadline.cancel();
    }
  }

  void dispose() => _http.close(force: true);
}
