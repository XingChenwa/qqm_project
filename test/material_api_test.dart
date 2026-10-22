import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qq_bot_manager/models/media_image.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/material_image_upload.dart';

const cosUrl =
    'https://fixture-123.cos.ap-guangzhou.myqcloud.com/image?signature=fixture';
const reference = 'qqbot-media://image/v1/fixture_token';
Map<String, dynamic> imageJson(String id, {String? token}) => {
  'image_id': id,
  'url': 'qqbot-media://image/v1/${token ?? id}',
  'file_name': '$id.png',
  'preview_url': cosUrl,
  'created_at': 1792560000,
  'expires_at': 1992560000,
};

class MaterialAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  final bodies = <List<int>>[];
  MaterialAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final bytes = <int>[];
    if (stream != null) {
      await for (final data in stream) {
        bytes.addAll(data);
      }
    }
    bodies.add(bytes);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Map<String, dynamic> value, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
Dio client(MaterialAdapter adapter) =>
    Dio(BaseOptions(validateStatus: (_) => true))..httpClientAdapter = adapter;
Future<MaterialUploadImage> pngImage() => MaterialUploadImage.fromBytes(
  img.encodePng(img.Image(width: 4, height: 3)),
  '测试.png',
);

void main() {
  test('素材验证真实格式、10MB和尺寸边界；GIF不转换、不丢动画原字节', () async {
    final image = img.Image(width: 3, height: 2);
    final gif = Uint8List.fromList(img.encodeGif(image));
    final prepared = await MaterialUploadImage.fromBytes(gif, '错误扩展名.jpg');
    expect(prepared.bytes, gif);
    expect(prepared.contentType, 'image/gif');
    expect(prepared.filename, '错误扩展名.gif');
    expect(prepared.md5Hex, md5.convert(gif).toString());
    expect(prepared.sha1Hex, sha1.convert(gif).toString());
    final jpeg = await MaterialUploadImage.fromBytes(
      img.encodeJpg(image),
      'photo.jpg',
    );
    expect(jpeg.filename, 'photo.jpeg');
    expect(jpeg.contentType, 'image/jpeg');
    for (final data in [
      Uint8List(0),
      Uint8List(MaterialUploadImage.maxBytes + 1),
      Uint8List.fromList(utf8.encode('<html>not an image</html>')),
      img.encodeBmp(image),
      img.encodePng(img.Image(width: 8193, height: 1)),
    ]) {
      await expectLater(
        MaterialUploadImage.fromBytes(data, 'fake.png'),
        throwsFormatException,
      );
    }
  });

  test('引用、COS地址和Markdown标签均校验，临时预览无持久化序列化入口', () {
    expect(isMediaReference(reference), isTrue);
    for (final value in [
      '$reference?q=1',
      '$reference#fragment',
      'qqbot-media://other/v1/token',
      'qqbot-media://user@image/v1/token',
      'qqbot-media://image:123/v1/token',
      '$reference)',
    ]) {
      expect(isMediaReference(value), isFalse, reason: value);
    }
    expect(isMaterialCosUrl(cosUrl), isTrue);
    for (final url in [
      'http://fixture.cos.ap-guangzhou.myqcloud.com/x',
      'https://evil.example/x',
      'https://127.0.0.1/x',
      'https://fixture.cos.ap-guangzhou.myqcloud.com.evil.example/x',
      'https://user@fixture.cos.ap-guangzhou.myqcloud.com/x',
    ]) {
      expect(isMaterialCosUrl(url), isFalse);
    }
    final material = BotMediaImage.fromMap({
      ...imageJson('id'),
      'file_name': 'a]\n[bad.png',
    });
    expect(material.markdown, '![图片 #320px #320px](qqbot-media://image/v1/id)');
    expect(
      BotMediaImage.fromMap({
        ...imageJson('id'),
        'preview_url': 'https://evil.example/x',
      }).previewUrl,
      isEmpty,
    );
  });

  test('prepare → 原始二进制PUT → complete，COS绝不携带QQ鉴权且ETag一致', () async {
    final image = await pngImage();
    final qq = MaterialAdapter(
      (r) => r.path.endsWith('/prepare')
          ? jsonBody({
              'upload_id': 'task',
              'presigned_url': cosUrl,
              'expires_in': 3600,
            })
          : jsonBody({
              'image_id': 'id',
              'url': reference,
              'ttl': 7776000,
              'preview_url': cosUrl,
            }),
    );
    final cos = MaterialAdapter(
      (r) => ResponseBody.fromString(
        '',
        200,
        headers: {
          'etag': ['"${image.md5Hex}"'],
        },
      ),
    );
    final api = ApiService(dio: client(qq), materialUploads: client(cos));
    final stages = <String>[];
    final result = await api.uploadMediaImage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'test-qq-token',
      image: image,
      onProgress: (s, _) => stages.add(s),
    );
    expect(result.isSuccess, isTrue, reason: result.error);
    expect(result.data!.reference, reference);
    expect(result.data!.filename, image.filename);
    expect(qq.requests.map((r) => r.path).toList(), [
      'https://api.bot.qq.com/v2/media-images/prepare',
      'https://api.bot.qq.com/v2/media-images/complete',
    ]);
    expect(qq.requests.first.data, {
      'file_name': image.filename,
      'file_size': image.bytes.length,
      'content_type': 'image/png',
      'md5': image.md5Hex,
      'sha1': image.sha1Hex,
    });
    expect(qq.requests.last.data, {'upload_id': 'task', 'md5': image.md5Hex});
    expect(cos.requests.single.method, 'PUT');
    expect(cos.requests.single.contentType, 'image/png');
    expect(cos.bodies.single, image.bytes);
    expect(
      cos.requests.single.headers.toString(),
      isNot(contains('test-qq-token')),
    );
    expect(
      cos.requests.single.headers.keys.any(
        (k) => k.toLowerCase() == 'authorization',
      ),
      isFalse,
    );
    expect(cos.requests.single.followRedirects, isFalse);
    expect(qq.requests.every((r) => !r.followRedirects), isTrue);
    expect(stages.last, '上传完成');
  });

  test('ETag不符、COS拒绝或重定向均不complete，不把预签名URL写进错误', () async {
    final image = await pngImage();
    for (final status in [200, 302, 403]) {
      final qq = MaterialAdapter(
        (_) => jsonBody({
          'upload_id': 'task',
          'presigned_url': cosUrl,
          'expires_in': 3600,
        }),
      );
      final cos = MaterialAdapter(
        (_) => ResponseBody.fromString(
          'signature=private',
          status,
          headers: {
            'etag': ['00000000000000000000000000000000'],
            'location': ['https://evil.example'],
          },
        ),
      );
      final result =
          await ApiService(
            dio: client(qq),
            materialUploads: client(cos),
          ).uploadMediaImage(
            baseUrl: 'https://api.bot.qq.com',
            accessToken: 'token',
            image: image,
          );
      expect(result.isSuccess, isFalse);
      expect(qq.requests.length, 1);
      expect(cos.requests.length, 1);
      expect(result.error, isNot(contains('signature=')));
      expect(result.error, isNot(contains('private')));
    }
  });

  test('不信任prepare返回的任意上传地址；上传中切换机器人不再complete', () async {
    final image = await pngImage();
    final cos = MaterialAdapter((_) => throw StateError('must not upload'));
    final qq = MaterialAdapter(
      (_) => jsonBody({
        'upload_id': 'task',
        'presigned_url': 'https://evil.example/upload',
        'expires_in': 3600,
      }),
    );
    final rejected =
        await ApiService(
          dio: client(qq),
          materialUploads: client(cos),
        ).uploadMediaImage(
          baseUrl: 'https://api.bot.qq.com',
          accessToken: 'token',
          image: image,
        );
    expect(rejected.isSuccess, isFalse);
    expect(cos.requests, isEmpty);
    var current = true;
    final safeQq = MaterialAdapter(
      (_) => jsonBody({
        'upload_id': 'task',
        'presigned_url': cosUrl,
        'expires_in': 3600,
      }),
    );
    final switching = MaterialAdapter((_) {
      current = false;
      return ResponseBody.fromString(
        '',
        200,
        headers: {
          'etag': [image.md5Hex],
        },
      );
    });
    final result =
        await ApiService(
          dio: client(safeQq),
          materialUploads: client(switching),
        ).uploadMediaImage(
          baseUrl: 'https://api.bot.qq.com',
          accessToken: 'token',
          image: image,
          isCurrent: () => current,
        );
    expect(result.error, contains('机器人已切换'));
    expect(safeQq.requests.length, 1);
  });

  test('官方列表游标、删除路径与素材错误码保留', () async {
    final qq = MaterialAdapter(
      (r) => r.method == 'DELETE'
          ? jsonBody({})
          : jsonBody({
              'images': [imageJson('id')],
              'next_cursor': 'page2',
              'total': 3,
            }),
    );
    final api = ApiService(dio: client(qq));
    final page = await api.listMediaImages(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      cursor: 'x=y&z',
    );
    expect(page.data!.images.single.id, 'id');
    expect(page.data!.cursor, 'page2');
    expect(qq.requests.single.queryParameters, {'cursor': 'x=y&z'});
    expect(
      (await api.deleteMediaImage(
        baseUrl: 'https://api.bot.qq.com',
        accessToken: 'token',
        imageId: 'id',
      )).isSuccess,
      isTrue,
    );
    expect(qq.requests.last.uri.path, '/v2/media-images/id/delete');
    final denied = MaterialAdapter(
      (_) => jsonBody({'code': 40035007, 'message': 'quota'}, 400),
    );
    final result = await ApiService(
      dio: client(denied),
    ).listMediaImages(baseUrl: 'https://api.bot.qq.com', accessToken: 'token');
    expect(result.errorCode, 40035007);
    expect(result.error, contains('100 张上限'));
  });
}
