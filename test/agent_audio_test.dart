import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/audio.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/js_packages.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'agent_js_packages_test.dart' as fixture;

Uint8List sampleWav() {
  final bytes = Uint8List(44 + 4400), b = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  b.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 22000, Endian.little);
  b.setUint32(28, 44000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  b.setUint32(40, 4400, Endian.little);
  return bytes;
}

class AudioHttp extends AgentHttp {
  final requests =
      <({Uri uri, Object? body, Map<String, String> headers, int timeout})>[];
  final wave = sampleWav();
  bool fail = false;
  @override
  Future<({Uint8List bytes, int status, Map<String, String> headers})>
  fetchBytes(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    CancelToken? cancel,
    int maxBytes = 12 * 1024 * 1024,
    int timeoutSeconds = 15,
  }) async {
    requests.add((
      uri: uri,
      body: body,
      headers: headers,
      timeout: timeoutSeconds,
    ));
    Object value;
    if (uri.path.endsWith('/upload')) {
      expect(body, isA<Uint8List>());
      final raw = body as Uint8List;
      expect(raw.length, greaterThan(600000));
      expect(
        ascii.decode(raw.take(200).toList(), allowInvalid: true),
        contains('filename="reference.wav"'),
      );
      expect(raw.any((b) => b > 127), true);
      value = ['/tmp/gradio/reference.wav'];
    } else if (uri.path.endsWith('/generate')) {
      final payload = object(jsonDecode(body as String));
      expect((payload['data'] as List).first, '你好，这是语音测试');
      value = {'event_id': 'fixture-event'};
    } else if (uri.path.endsWith('/fixture-event')) {
      return (
        bytes: Uint8List.fromList(
          utf8.encode(
            fail
                ? 'event: error\ndata: 后端测试失败\n\n'
                : 'event: complete\ndata: [{"url":"https://voice.fixture.test/result.wav"}]\n\n',
          ),
        ),
        status: 200,
        headers: {'content-type': 'text/event-stream'},
      );
    } else {
      return (bytes: wave, status: 200, headers: {'content-type': 'audio/wav'});
    }
    return (
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(value))),
      status: 200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  final folder = Platform.environment['QQM_AGENT_EXTRA_PACKAGE_DIR'];
  final skip = Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] == null
      ? '需要测试JavaScript引擎'
      : false;
  group('语音与二进制上传桥接', () {
    late AgentStore store;
    late AudioHttp http;
    late AgentJsPackages runner;
    setUp(() async {
      store = AgentStore.memory();
      await store.open();
      http = AudioHttp();
      runner = AgentJsPackages(store, http);
    });
    tearDown(() async {
      await runner.drain();
      http.close();
      await store.close();
    });
    test('原始VoxCPM ZIP完成二进制multipart、SSE、取回WAV与语音回执', () async {
      if (folder == null) return;
      final extension = AgentExtension.fromPackage(
        await File('$folder/skills-voxcpm-voice.zip').readAsBytes(),
      );
      var sent = 0;
      final result = await runner.run(
        manifest: extension.manifest,
        settings: {
          ...extension.config,
          'apiBase': 'https://voice.fixture.test',
        },
        operation: 'tool',
        scope: 'voice',
        input: {'chatKey': 'current'},
        args: {
          'id': 'read_aloud',
          'args': {'text': '你好，这是语音测试'},
        },
        active: () => true,
        sendMedia: (bytes, name, type) async {
          expect(bytes, http.wave);
          expect(name, 'voice.wav');
          expect(type, 'record');
          sent++;
          return {'ok': true, 'message_id': 'ack'};
        },
      );
      expect(result['isError'], false, reason: text(result['content']));
      expect(sent, 1);
      expect(http.requests, hasLength(4));
      expect(http.requests.every((r) => r.timeout == 120), true);
      expect(jsonEncode(store.all('js-volume')), isNot(contains('.mp3')));
    });
    test('Blob与FormData真实编码，发送到其他会话被拒绝', () async {
      final e = AgentExtension.fromPackage(
        fixture.bundle(
          extra: {
            'permissions': ['web_fetch'],
          },
          source: r'''
        export function setup(api){api.registerTool({id:'form',parameters:{type:'object',properties:{}},async execute(ctx){
          const form=new FormData();form.append('text','中文');form.append('files',new Blob([new Uint8Array([0,255,1,254])],{type:'audio/wav'}),'test.wav');
          await api.fetch('https://upload.fixture.test/form',{method:'POST',body:form});
          let denied=false;try{await ctx.sender.sendMedia('foreign',[{type:'record',data:{file:'/data/foreign'}}]);}catch{denied=true;}
          return {content:String(denied)};
        }});}
      ''',
        ),
      );
      final result = await runner.run(
        manifest: e.manifest,
        settings: e.config,
        operation: 'tool',
        input: {'chatKey': 'current'},
        args: {'id': 'form', 'args': {}},
        active: () => true,
      );
      expect(result['content'], 'true');
      final body = http.requests.single.body as Uint8List;
      expect(
        http.requests.single.headers['Content-Type'],
        startsWith('multipart/form-data; boundary='),
      );
      expect(utf8.decode(body, allowMalformed: true), contains('中文'));
      expect(body, containsAllInOrder([0, 255, 1, 254]));
    });
    test('合成失败不会发送语音，也不会向模型回报已发送', () async {
      if (folder == null) return;
      http.fail = true;
      final e = AgentExtension.fromPackage(
        await File('$folder/skills-voxcpm-voice.zip').readAsBytes(),
      );
      var sent = 0;
      final result = await runner.run(
        manifest: e.manifest,
        settings: {...e.config, 'apiBase': 'https://voice.fixture.test'},
        operation: 'tool',
        scope: 'failed',
        input: {'chatKey': 'current'},
        args: {
          'id': 'read_aloud',
          'args': {'text': '你好，这是语音测试'},
        },
        active: () => true,
        sendMedia: (bytes, name, type) async {
          sent++;
          return {};
        },
      );
      expect(result['isError'], true);
      expect(result['content'], contains('后端测试失败'));
      expect(sent, 0);
    });
  }, skip: skip);
  test('检测真实格式而不是照服务返回的.mp3后缀命名，拒绝伪装HTML', () {
    expect(AgentAudio(sampleWav()).name, 'voice.wav');
    expect(
      () => AgentAudio(Uint8List.fromList(utf8.encode('<html>error</html>'))),
      throwsA(isA<AgentException>()),
    );
  });
}
