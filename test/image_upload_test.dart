import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/image_upload_service.dart';

class MediaAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final ResponseBody Function(RequestOptions, int) respond;
  MediaAdapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options, requests.length);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(Map<String, Object> value, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  test('GIF 表情取首帧转为 PNG，文件名和图片二进制格式一致', () async {
    final image = img.Image(width: 3, height: 2);
    img.fill(image, color: img.ColorRgb8(20, 100, 220));
    final gif = Uint8List.fromList(img.encodeGif(image));
    final prepared = await const ImageUploadService().prepare(
      gif,
      '表情.gif',
    );
    expect(prepared.filename, '表情.png');
    expect(prepared.bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final decoded = img.decodePng(prepared.bytes)!;
    expect(decoded.width, 3);
    expect(decoded.height, 2);
    expect(decoded.getPixel(0, 0).b, img.decodeGif(gif)!.getPixel(0, 0).b);
  });

  test('拒绝伪图片 HTML、空文件和超限分辨率，不伪装成可发送图片', () async {
    final images = const ImageUploadService();
    for (final data in [
      Uint8List.fromList(utf8.encode('<html>403 Forbidden</html>')),
      Uint8List(0),
    ]) {
      await expectLater(
        images.prepare(data, 'fake.png'),
        throwsFormatException,
      );
    }
    final data = img.encodePng(img.Image(width: 8193, height: 1));
    await expectLater(
      images.prepare(data, 'too-wide.png'),
      throwsFormatException,
    );
  });

  test('QQ 下载 URL 失败时才本地下载直传，下载不携带机器人凭证且只发送一次消息', () async {
    final bytes = img.encodePng(img.Image(width: 2, height: 2));
    final remote = MediaAdapter(
      (_, _) => ResponseBody.fromBytes(
        bytes,
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      ),
    );
    final qq = MediaAdapter((request, index) {
      if (index == 1) {
        return jsonResponse({
          'code': 850026,
          'message': 'download failed',
        }, 400);
      }
      if (request.uri.path.endsWith('/files')) {
        return jsonResponse({'file_info': 'prepared-file'});
      }
      return jsonResponse({'id': 'sent-image'});
    });
    final api = ApiService(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = qq,
      images: ImageUploadService(
        downloadClient: Dio()..httpClientAdapter = remote,
      ),
    );
    final result = await api.sendQQImage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'secret-token',
      targetId: 'group-openid',
      isGroup: true,
      imageUrl: 'https://images.example/picture.png',
      msgId: 'passive-id',
      msgSeq: 3,
    );
    expect(result.isSuccess, isTrue);
    expect(qq.requests.length, 3);
    expect(qq.requests[0].data['url'], 'https://images.example/picture.png');
    expect(qq.requests[1].data['file_data'], base64Encode(bytes));
    expect(qq.requests[1].data.containsKey('url'), isFalse);
    expect(qq.requests[1].data['srv_send_msg'], isFalse);
    expect(qq.requests.last.data['msg_id'], 'passive-id');
    expect(qq.requests.last.data['msg_seq'], 3);
    expect(qq.requests.last.data['media'], {'file_info': 'prepared-file'});
    expect(
      remote.requests.single.headers.keys.any(
        (key) => key.toLowerCase() == 'authorization',
      ),
      isFalse,
    );
    expect(
      remote.requests.single.headers.toString(),
      isNot(contains('secret-token')),
    );
  });

  test('远程 GIF 先转 PNG，平台禁言或限流不触发下载重试', () async {
    final remote = MediaAdapter(
      (_, _) => ResponseBody.fromBytes(
        img.encodeGif(img.Image(width: 1, height: 1)),
        200,
      ),
    );
    final qq = MediaAdapter(
      (request, _) => request.uri.path.endsWith('/files')
          ? jsonResponse({'file_info': 'gif-file'})
          : jsonResponse({'id': 'gif-sent'}),
    );
    final api = ApiService(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = qq,
      images: ImageUploadService(
        downloadClient: Dio()..httpClientAdapter = remote,
      ),
    );
    final result = await api.sendQQImage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'g',
      isGroup: true,
      imageUrl: 'https://example.com/表情.gif',
    );
    expect(result.isSuccess, isTrue);
    expect(qq.requests.length, 2);
    expect(qq.requests.first.data['file_name'], '表情.png');
    expect(qq.requests.first.data.containsKey('url'), isFalse);
    final forbidden = MediaAdapter(
      (_, _) => jsonResponse({'code': 850018, 'message': 'muted'}, 400),
    );
    final deniedApi = ApiService(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = forbidden,
      images: ImageUploadService(
        downloadClient: Dio()..httpClientAdapter = remote,
      ),
    );
    final denied = await deniedApi.sendQQImage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'g',
      isGroup: true,
      imageUrl: 'https://example.com/photo.png',
    );
    expect(denied.errorCode, 850018);
    expect(denied.error, contains('禁言'));
    expect(forbidden.requests.length, 1);
    expect(remote.requests.length, 1);
  });

  test('表情下载为 HTML 或声明超过 5MB 时不会继续发送富媒体消息', () async {
    for (final large in [false, true]) {
      final remote = MediaAdapter(
        (_, _) => ResponseBody.fromString(
          '<html>not an image</html>',
          200,
          headers: {
            if (large)
              Headers.contentLengthHeader: [
                '${ImageUploadService.maxBytes + 1}',
              ],
          },
        ),
      );
      final qq = MediaAdapter(
        (_, _) =>
            jsonResponse({'code': 850026, 'message': 'download failed'}, 400),
      );
      final api = ApiService(
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = qq,
        images: ImageUploadService(
          downloadClient: Dio()..httpClientAdapter = remote,
        ),
      );
      final result = await api.sendQQImage(
        baseUrl: 'https://api.bot.qq.com',
        accessToken: 'token',
        targetId: 'g',
        isGroup: true,
        imageUrl: 'https://example.com/image.png',
      );
      expect(result.isSuccess, isFalse);
      expect(result.error, contains(large ? '5 MB' : '不是有效图片'));
      expect(qq.requests.length, 1);
    }
  });
}
