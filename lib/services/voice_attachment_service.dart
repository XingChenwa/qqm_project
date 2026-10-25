import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/received_message.dart';
import '../utils/voice_file.dart';

class PreparedVoice {
  final Directory directory;
  final File source;
  final String extension;
  PreparedVoice(this.directory, this.source, this.extension);
  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

class VoiceAttachmentService {
  static const maxBytes = 20 * 1024 * 1024;
  final Dio _dio;
  VoiceAttachmentService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              maxRedirects: 3,
            ),
          );

  Future<PreparedVoice> prepareBytes(
    Uint8List bytes,
    CancelToken cancel,
  ) async {
    if (cancel.isCancelled || bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('语音数据为空、超过 20 MB 或任务已取消');
    }
    final extension = voiceFileExtension(bytes);
    if (extension == 'bin') throw const FormatException('无法识别语音格式');
    final directory = await (await getTemporaryDirectory()).createTemp(
      'qqm-voice-',
    );
    try {
      if (cancel.isCancelled) throw const FormatException('语音任务已取消');
      final source = await File(
        p.join(directory.path, 'source.$extension'),
      ).writeAsBytes(bytes, flush: true);
      return PreparedVoice(directory, source, extension);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<PreparedVoice> prepare(
    ReceivedAttachment attachment,
    CancelToken cancel, {
    bool allowLocalFile = false,
  }) async {
    final uri = Uri.tryParse(attachment.openUrl);
    if (allowLocalFile &&
        uri?.scheme != 'https' &&
        uri?.scheme != 'http' &&
        attachment.openUrl.isNotEmpty) {
      final file = uri?.scheme == 'file'
          ? File.fromUri(uri!)
          : File(attachment.openUrl);
      if (!await file.exists() || await file.length() > maxBytes) {
        throw const FormatException('原语音文件已移动、删除或超过 20 MB。');
      }
      final directory = await (await getTemporaryDirectory()).createTemp(
        'qqm-voice-',
      );
      try {
        final bytes = await file.readAsBytes();
        if (bytes.length > maxBytes) throw const FormatException('语音超过 20 MB');
        final extension = voiceFileExtension(bytes);
        if (!RegExp(r'^[a-z0-9]{1,8}$').hasMatch(extension)) {
          throw const FormatException('无法识别原语音格式');
        }
        final copied = await File(
          p.join(directory.path, 'source.$extension'),
        ).writeAsBytes(bytes, flush: true);
        return PreparedVoice(directory, copied, extension);
      } catch (_) {
        await directory.delete(recursive: true);
        rethrow;
      }
    }
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('语音链接无效');
    }
    // A separate unauthenticated client: bot credentials are never sent to media hosts.
    final response = await _dio.get<ResponseBody>(
      uri.toString(),
      options: Options(responseType: ResponseType.stream),
      cancelToken: cancel,
    );
    final body = response.data;
    if (body == null) throw const FormatException('语音下载失败');
    if ((int.tryParse(response.headers.value('content-length') ?? '') ?? 0) >
        maxBytes) {
      cancel.cancel();
      throw const FormatException('语音超过 20 MB，请使用原文件链接下载');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (builder.length + chunk.length > maxBytes) {
        cancel.cancel();
        throw const FormatException('语音超过 20 MB');
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) throw const FormatException('语音文件为空');
    final extension = voiceFileExtension(bytes);
    final directory = await (await getTemporaryDirectory()).createTemp(
      'qqm-voice-',
    );
    try {
      final file = await File(
        p.join(directory.path, 'source.$extension'),
      ).writeAsBytes(bytes, flush: true);
      return PreparedVoice(directory, file, extension);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }
}
