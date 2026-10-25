// One explicit, short public-service synthesis test. No QQ connection or user
// model/chat/configuration is opened. The transport ACK is a local fixture.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:archive/archive.dart';
import 'package:qq_bot_manager/agent/audio.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/js_packages.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';

class TraceHttp extends AgentHttp {
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
    final clock = Stopwatch()..start();
    final label = uri.path.startsWith('/file=') ? '/file=(audio)' : uri.path;
    try {
      final value = await super.fetchBytes(
        uri,
        method: method,
        headers: headers,
        body: body,
        cancel: cancel,
        maxBytes: maxBytes,
        timeoutSeconds: timeoutSeconds,
      );
      stdout.writeln(
        jsonEncode({
          'method': method,
          'path': label,
          'status': value.status,
          'ms': clock.elapsedMilliseconds,
        }),
      );
      return value;
    } catch (error) {
      stdout.writeln(
        jsonEncode({
          'method': method,
          'path': label,
          'ms': clock.elapsedMilliseconds,
          'error': error.runtimeType.toString(),
        }),
      );
      rethrow;
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 1 ||
      !{'--live', '--metadata', '--emotions'}.contains(args.single)) {
    stderr.writeln('仅显式 --live 才向配置的公共 TTS 服务发送固定测试文字；不连接或发送到 QQ。');
    exitCode = 64;
    return;
  }
  final store = AgentStore.memory();
  await store.open();
  final http = TraceHttp();
  final runner = AgentJsPackages(store, http);
  File? audioFile;
  try {
    final archive = Archive();
    for (final name in [
      'skill.json',
      'index.js',
      'service.json',
      'README.md',
    ]) {
      final bytes = await File('agent_examples/yy-tts/$name').readAsBytes();
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    final extension = AgentExtension.fromPackage(ZipEncoder().encode(archive));
    final found = await runner.run(
      manifest: extension.manifest,
      settings: {...extension.config, 'delivery': 'download'},
      operation: 'inspect',
      active: () => true,
    );
    final output = await runner.run(
      manifest: extension.manifest,
      settings: {...extension.config, 'delivery': 'download'},
      operation: 'tool',
      scope: 'local-tts-synthesis-test',
      input: {'chatKey': 'private:local-test'},
      args: args.single == '--emotions'
          ? {'id': 'list_emotions', 'args': <String, dynamic>{}}
          : args.single == '--metadata'
          ? {
              'id': 'list_voices',
              'args': {'query': '11号'},
            }
          : {
              'id': 'read_aloud',
              'args': {'text': '你好，语音测试。'},
            },
      active: () => true,
      sendMedia: (bytes, name, type) async {
        final audio = AgentAudio(bytes);
        await Directory('build/yy-tts-preview').create(recursive: true);
        audioFile = File('build/yy-tts-preview/test.${audio.extension}');
        await audioFile!.writeAsBytes(bytes, flush: true);
        return {'message_id': 'local-fixture-only'};
      },
    );
    stdout.writeln(
      jsonEncode({
        'loaded': (found['tools'] as List).length == 3,
        'synthesis': audioFile != null,
        'qqSendTested': false,
        'audio': audioFile?.absolute.path,
        if (output['isError'] == true) 'error': text(output['content']),
      }),
    );
    if ((args.single == '--live' && audioFile == null) ||
        output['isError'] == true) {
      exitCode = 1;
    }
  } catch (error) {
    stdout.writeln(
      jsonEncode({
        'synthesis': false,
        'qqSendTested': false,
        'errorType': error.runtimeType.toString(),
      }),
    );
    exitCode = 1;
  } finally {
    await runner.drain();
    http.close();
    await store.close();
  }
}
