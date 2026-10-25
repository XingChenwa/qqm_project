import 'dart:convert';
import 'dart:io';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/js_packages.dart';

Future<void> main(List<String> args) async {
  final store = AgentStore.memory();
  await store.open();
  final http = AgentHttp();
  final packages = AgentJsPackages(store, http);
  try {
    if (args.contains('--check-network')) {
      final r = await http.fetchBytes(
        Uri.parse('https://aigengtu.com/gallery-index.json'),
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'reply-meme/1.0 (+https://aigengtu.com/)',
          'Referer': 'https://aigengtu.com/',
        },
      );
      Object? gallery;
      try {
        gallery = jsonDecode(utf8.decode(r.bytes));
      } catch (_) {}
      stdout.writeln(
        jsonEncode({
          'publicGalleryStatus': r.status,
          'bytes': r.bytes.length,
          'galleryPresent': gallery is Map && gallery['gallery'] is Map,
        }),
      );
    }
    for (final filename in args.where((a) => !a.startsWith('--'))) {
      final extension = AgentExtension.fromPackage(
        await File(filename).readAsBytes(),
      );
      final found = await packages.run(
        manifest: extension.manifest,
        settings: extension.config,
        operation: 'inspect',
        active: () => true,
      );
      stdout.writeln(
        jsonEncode({'package': extension.id, 'inspection': found}),
      );
      if (extension.id == 'trendy-memes') {
        final result = await packages.run(
          manifest: extension.manifest,
          settings: extension.config,
          operation: 'tool',
          args: {
            'id': 'lookup',
            'args': {'term': '抽象'},
          },
          active: () => true,
        );
        stdout.writeln(jsonEncode({'lookup': result}));
      }
      if (extension.id == 'owner-identity') {
        final result = await packages.run(
          manifest: extension.manifest,
          settings: {...extension.config, 'ids': '2377130783'},
          operation: 'plugin',
          input: {
            'kind': 'private',
            'selfId': '123456',
            'triggerEntries': [
              {'senderId': '2377130783'},
            ],
            'persona': {'roleText': '普通人设'},
          },
          active: () => true,
        );
        stdout.writeln(jsonEncode({'owner': result}));
      }
      if (extension.id == 'reply-meme' && args.contains('--check-meme')) {
        var downloadedImages = 0, totalBytes = 0;
        final result = await packages.run(
          manifest: extension.manifest,
          settings: extension.config,
          operation: 'tool',
          scope: 'local-network-validation',
          input: {'chatKey': 'dry-run-no-qq-account'},
          args: {
            'id': 'find_meme',
            'args': {'mode': 'request', 'keyword': '谢谢'},
          },
          active: () => true,
          sendImage: (bytes, name) async {
            downloadedImages++;
            totalBytes += bytes.length;
            return {'ok': true, 'dryRun': true};
          },
        );
        Object? content;
        try {
          content = jsonDecode(result['content']?.toString() ?? '');
        } catch (_) {}
        stdout.writeln(
          jsonEncode({
            'liveOriginalPackage': extension.id,
            'dryRunNoQqMessage': true,
            'downloadedImages': downloadedImages,
            'imageBytes': totalBytes,
            'result': content,
            'logs': result['_logs'],
          }),
        );
      }
    }
  } finally {
    http.close();
    await store.close();
  }
}
