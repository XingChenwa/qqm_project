// Offline protocol tests: no real QQ account, task, credentials or network.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/services/qq_qr_login_service.dart';

class QrAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions) handler;
  final requests = <RequestOptions>[];
  QrAdapter(this.handler);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody qrResponse(Map<String, dynamic> data) => ResponseBody.fromString(
  jsonEncode({'retcode': 0, 'data': data}),
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

Future<void> waitQr(QqQrLoginService service, QrLoginPhase phase) async {
  if (service.phase == phase) return;
  final result = Completer<void>();
  void listener() {
    if (service.phase == phase && !result.isCompleted) result.complete();
  }

  service.addListener(listener);
  try {
    await result.future.timeout(const Duration(seconds: 8));
  } finally {
    service.removeListener(listener);
  }
}

QqQrLoginService testQrService(
  QrAdapter adapter, {
  Duration lifetime = const Duration(seconds: 10),
}) => QqQrLoginService(
  http: Dio()..httpClientAdapter = adapter,
  pollInterval: const Duration(milliseconds: 20),
  lifetime: lifetime,
);

void main() {
  test('官方绑定协议：本机随机密钥、状态推进、GCM 解密；授权不等于自动保存', () async {
    List<int>? bindingKey;
    var polls = 0;
    final api = QrAdapter((request) async {
      expect(request.uri.origin, 'https://q.qq.com');
      expect(request.method, 'POST');
      expect(request.followRedirects, isFalse);
      expect(request.headers.containsKey('Authorization'), isFalse);
      if (request.uri.path.endsWith('create_bind_task')) {
        expect((request.data as Map).keys, ['key']);
        bindingKey = base64Decode(request.data['key'] as String);
        expect(bindingKey, hasLength(32));
        return qrResponse({'task_id': 'fixture-task_1'});
      }
      expect(request.data, {'task_id': 'fixture-task_1'});
      polls++;
      if (polls == 1) return qrResponse({'status': 0});
      if (polls == 2) return qrResponse({'status': 1});
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode('fixture-only-app-secret'),
        secretKey: SecretKey(bindingKey!),
        nonce: List.generate(12, (i) => i + 1),
      );
      return qrResponse({
        'status': 2,
        'bot_appid': '100000001',
        'bot_encrypt_secret': base64Encode([
          ...box.nonce,
          ...box.cipherText,
          ...box.mac.bytes,
        ]),
      });
    });
    final service = testQrService(api);
    addTearDown(service.dispose);
    await service.start();
    expect(service.phase, QrLoginPhase.waiting);
    expect(service.qrUri!.queryParameters, {
      'task_id': 'fixture-task_1',
      'source': '',
      '_wv': '2',
    });
    expect(
      service.qrUri.toString(),
      isNot(contains(base64Encode(bindingKey!))),
    );
    await waitQr(service, QrLoginPhase.pending);
    expect(service.message, isNot(contains('已扫码')));
    await waitQr(service, QrLoginPhase.authorized);
    expect(service.credentials!.appId, '100000001');
    expect(service.credentials!.appSecret, 'fixture-only-app-secret');
    expect(
      service.credentials.toString(),
      isNot(contains('fixture-only-app-secret')),
    );
    expect(service.qrUri, isNull);
    service.markSaved();
    expect(service.credentials, isNull);
    expect(service.phase, QrLoginPhase.saved);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(polls, 3);
  });

  final invalid = [
    {
      'status': 2,
      'bot_appid': '100000001',
      'bot_encrypt_secret': base64Encode(List.filled(40, 0)),
    },
    {
      'status': 2,
      'bot_appid': 'bad/id',
      'bot_encrypt_secret': 'secret-response-must-not-leak',
    },
    {'status': 99},
  ];
  for (var index = 0; index < invalid.length; index++) {
    test('篡改或非法授权结果拒绝并清理 #$index', () async {
      final api = QrAdapter(
        (r) async => qrResponse(
          r.uri.path.endsWith('create_bind_task')
              ? {'task_id': 'test'}
              : invalid[index],
        ),
      );
      final service = testQrService(api);
      addTearDown(service.dispose);
      await service.start();
      await waitQr(service, QrLoginPhase.failed);
      expect(service.credentials, isNull);
      expect(service.qrUri, isNull);
      expect(service.message, isNot(contains('secret-response')));
    });
  }

  test('官方过期状态和本地截止时间都会停止轮询', () async {
    var expired = true;
    final api = QrAdapter(
      (r) async => qrResponse(
        r.uri.path.endsWith('create_bind_task')
            ? {'task_id': 'test'}
            : {'status': expired ? 3 : 0},
      ),
    );
    final service = testQrService(
      api,
      lifetime: const Duration(milliseconds: 180),
    );
    addTearDown(service.dispose);
    await service.start();
    await waitQr(service, QrLoginPhase.expired);
    expired = false;
    await service.start();
    await waitQr(service, QrLoginPhase.expired);
    final count = api.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(api.requests.length, count);
    expect(service.qrUri, isNull);
  });

  test('取消后，旧异步响应不能回填凭据；后台不重复轮询', () async {
    final delayed = Completer<ResponseBody>();
    final firstPoll = Completer<void>();
    var polls = 0;
    final api = QrAdapter((r) async {
      if (r.uri.path.endsWith('create_bind_task')) {
        return qrResponse({'task_id': 'test'});
      }
      polls++;
      if (polls == 1) {
        firstPoll.complete();
        return delayed.future;
      }
      return qrResponse({'status': 0});
    });
    final service = testQrService(api);
    addTearDown(service.dispose);
    await service.start();
    await firstPoll.future;
    service.cancel();
    delayed.complete(
      qrResponse({
        'status': 2,
        'bot_appid': '100000001',
        'bot_encrypt_secret': 'ignored',
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.phase, QrLoginPhase.cancelled);
    expect(service.credentials, isNull);
    await service.start();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    service.setForeground(false);
    final count = api.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(api.requests.length, count);
    service.setForeground(true);
    service.setForeground(true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(api.requests.length, count + 1);
    service.cancel();
  });

  test('重定向与超大响应拒绝，错误不泄露服务正文或密钥', () async {
    for (final response in [
      ResponseBody.fromString(
        'private-service-error',
        302,
        headers: {
          'location': ['https://evil.invalid/'],
        },
      ),
      ResponseBody.fromString(
        'private-service-error'.padRight(65537, 'x'),
        200,
      ),
      ResponseBody.fromString(
        '{"retcode":1,"msg":"private-service-error"}',
        200,
      ),
    ]) {
      final api = QrAdapter((_) async => response);
      final service = testQrService(api);
      await service.start();
      expect(service.phase, QrLoginPhase.failed);
      expect(api.requests, hasLength(1));
      expect(service.message, isNot(contains('private-service-error')));
      service.dispose();
    }
  });

  test('查询网络失败最多重试三次；销毁后不再请求或通知', () async {
    final api = QrAdapter((r) async {
      if (r.uri.path.endsWith('create_bind_task')) {
        return qrResponse({'task_id': 'test'});
      }
      throw DioException(
        requestOptions: r,
        type: DioExceptionType.connectionTimeout,
      );
    });
    final service = testQrService(api);
    await service.start();
    await waitQr(service, QrLoginPhase.failed);
    expect(api.requests, hasLength(4));
    service.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(api.requests, hasLength(4));
  });
}
