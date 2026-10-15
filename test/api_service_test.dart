import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/services/api_service.dart';

class RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Object response = {'id': 'message-1'};
  int status = 200;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(response),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        'x-tps-trace-id': ['test-trace'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late RecordingAdapter adapter;
  late ApiService api;

  setUp(() {
    adapter = RecordingAdapter();
    api = ApiService(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter,
    );
  });

  test('群资料、成员和机器人资料使用官方 GET 地址和鉴权，白名单错误保留业务码', () async {
    adapter.response = {'group_openid': 'g', 'group_name': '读书分享会'};
    final group = await api.getGroupInfo(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      groupId: 'g',
    );
    expect(group.data?['group_name'], '读书分享会');
    await api.getGroupMemberInfo(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      groupId: 'g',
      memberId: 'm',
    );
    await api.getBotProfile(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
    );
    expect(adapter.requests.map((request) => request.uri.path), [
      '/v2/groups/g/info',
      '/v2/groups/g/members/m',
      '/users/@me',
    ]);
    expect(
      adapter.requests.every(
        (request) =>
            request.method == 'GET' &&
            request.headers['Authorization'] == 'QQBot token',
      ),
      isTrue,
    );
    adapter.response = {'code': 11253, 'message': 'permission denied'};
    final failure = await api.getGroupInfo(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      groupId: 'g',
    );
    expect(failure.errorCode, 11253);
    expect(failure.error, contains('白名单'));
  });

  test('多行代码以原生 Markdown 发送，正文和模板字段不会混入请求', () async {
    const code = '```python\n# 中文注释\nif True:\n    print("你好")\n```';
    final result = await api.sendQQMarkdown(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'group-id',
      isGroup: true,
      markdownContent: code,
      msgId: 'incoming-id',
      msgSeq: 2,
    );
    expect(result.isSuccess, isTrue);
    final request = adapter.requests.single;
    expect(request.uri.path, '/v2/groups/group-id/messages');
    expect(request.headers['Authorization'], 'QQBot token');
    expect(request.data, {
      'markdown': {'content': code},
      'msg_type': 2,
      'msg_id': 'incoming-id',
      'msg_seq': 2,
    });
  });

  test('HTTP 200 的业务错误不会被误报为发送成功，并保留中文原因和追踪 ID', () async {
    adapter.response = {'code': 40034009, 'message': 'invalid markdown params'};
    final result = await api.sendQQMarkdown(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'user-id',
      markdownContent: '# 测试',
    );
    expect(result.isSuccess, isFalse);
    expect(result.errorCode, 40034009);
    expect(result.error, contains('换行'));
    expect(result.traceId, 'test-trace');
  });

  test('没有消息 ID 的响应不能确认发送成功', () async {
    adapter.response = {'message': 'pending'};
    final result = await api.sendQQMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'user-id',
      content: '你好',
    );
    expect(result.isSuccess, isFalse);
  });

  test('模板参数使用 values 数组，多行代码和空模板 ID 会在请求前被拦截', () async {
    await api.sendQQMarkdown(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'user-id',
      templateId: 'template-id',
      templateParams: [
        {'key': 'title', 'value': '标题'},
      ],
    );
    expect(adapter.requests.single.data['markdown'], {
      'custom_template_id': 'template-id',
      'params': [
        {
          'key': 'title',
          'values': ['标题'],
        },
      ],
    });
    final multiline = await api.sendQQMarkdown(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'user-id',
      templateId: 'template-id',
      templateParams: [
        {'key': 'code', 'value': 'a\nb'},
      ],
    );
    final missingId = await api.sendQQMarkdown(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'user-id',
      templateId: '',
      markdownContent: '# 标题',
    );
    expect(multiline.isSuccess, isFalse);
    expect(missingId.isSuccess, isFalse);
    expect(adapter.requests, hasLength(1));
  });

  test('本地图片上传包含官方要求的文件名，发送包含 file_info 和兼容 content', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qqbot-upload-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/测试.png');
    final imageBytes = img.encodePng(img.Image(width: 2, height: 2));
    await file.writeAsBytes(imageBytes);
    adapter.response = {'file_info': 'file-info', 'id': 'image-id'};
    final result = await api.sendQQImage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'user-id',
      imageUrl: file.path,
    );
    expect(result.isSuccess, isTrue);
    expect(adapter.requests.first.data['file_name'], '测试.png');
    expect(adapter.requests.first.data['file_data'], base64Encode(imageBytes));
    expect(adapter.requests.last.data['media'], {'file_info': 'file-info'});
    expect(adapter.requests.last.data['content'], ' ');
  });

  test('使用最新凭证地址，HTTP 200 凭据错误保留原始业务错误码', () async {
    adapter.response = {'code': 100016, 'message': 'invalid appid or secret'};
    final result = await api.getAccessToken(
      appId: 'test',
      clientSecret: 'dummy',
    );
    expect(
      adapter.requests.single.uri.toString(),
      'https://api.bot.qq.com/app/getAppAccessToken',
    );
    expect(result.isSuccess, isFalse);
    expect(result.errorCode, 100016);
  });

  test('旧地址迁移到当前官方地址，同时保留用户自定义代理和沙箱', () {
    expect(
      BotConfig.fromMap({
        'apiBaseUrl': 'https://api.sgroup.qq.com/',
      }).resolvedApiBaseUrl,
      'https://api.bot.qq.com',
    );
    expect(
      BotConfig(apiBaseUrl: 'https://proxy.example/').resolvedApiBaseUrl,
      'https://proxy.example',
    );
    expect(
      BotConfig(useSandbox: true).resolvedApiBaseUrl,
      'https://sandbox.api.sgroup.qq.com',
    );
  });
}
