import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/gradio_events.dart';
import 'package:qq_bot_manager/agent/http.dart';

class EventAdapter implements HttpClientAdapter {
  final Stream<Uint8List> stream;
  final void Function() onClose;
  EventAdapter(this.stream, this.onClose);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody(
    stream,
    200,
    headers: {
      'content-type': ['text/event-stream; charset=utf-8'],
    },
  );
  @override
  void close({bool force = false}) => onClose();
}

class FixturePublicHttp extends AgentHttp {
  FixturePublicHttp(Dio Function() factory)
    : super(downloadDioFactory: factory);
  @override
  Future<List<InternetAddress>> validatePublicUri(Uri uri) async => [
    InternetAddress('203.0.113.1'),
  ];
}

void main() {
  test('只在完整Gradio终态帧结束读取，保留拆分CRLF和Unicode后的协议边界', () {
    final boundary = GradioEventBoundary();
    expect(
      boundary.add(
        utf8.encode(
          'data: {"msg":"process_generating","output":{"text":"process_completed"}}\n\n',
        ),
      ),
      false,
    );
    final frame = utf8.encode(
      'data: {"msg":"process_completed","success":true,"output":{"data":["语音"]}}\r\n\r\n',
    );
    for (var i = 0; i < frame.length - 1; i++) {
      expect(boundary.add([frame[i]]), false);
    }
    expect(boundary.add([frame.last]), true);
  });
  test('兼容call完成、错误和队列错误帧，畸形/过大事件不冒充终态', () {
    for (final frame in [
      'event: complete\ndata: []\n\n',
      'event: error\ndata: null\n\n',
      'data: {"msg":"queue_full"}\n\n',
    ]) {
      expect(GradioEventBoundary().add(utf8.encode(frame)), true);
    }
    final boundary = GradioEventBoundary();
    expect(boundary.add(utf8.encode('data: not json\n\n')), false);
    expect(boundary.add(utf8.encode('data: ${'x' * 300000}\n\n')), false);
    expect(boundary.add(utf8.encode('event: complete\ndata: []\n\n')), true);
  });
  test('真实下载器在服务器保持SSE连接时按完成事件返回并关闭客户端，不等待超时', () async {
    var closed = false;
    late StreamController<Uint8List> source;
    const packet =
        'data: {"msg":"process_completed","success":true,"output":{"data":[{"path":"/tmp/test.wav"}]}}\n\n';
    source = StreamController(
      onListen: () {
        scheduleMicrotask(() {
          source.add(
            Uint8List.fromList(utf8.encode('data: {"msg":"estimation"}\n\n')),
          );
          source.add(Uint8List.fromList(utf8.encode(packet)));
          // Intentionally never send EOF: this is how a shared queue can behave.
        });
      },
    );
    final http = FixturePublicHttp(
      () => Dio()
        ..httpClientAdapter = EventAdapter(source.stream, () {
          closed = true;
          unawaited(source.close());
        }),
    );
    try {
      final response = await http
          .fetchBytes(
            Uri.parse(
              'https://service.fixture.test/queue/data?session_hash=test',
            ),
            timeoutSeconds: 5,
          )
          .timeout(const Duration(seconds: 1));
      expect(response.status, 200);
      expect(utf8.decode(response.bytes), endsWith(packet));
      expect(closed, true);
    } finally {
      http.close();
      await source.close();
    }
  });
}
