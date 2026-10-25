import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:qq_bot_manager/agent/package_bundle.dart';

Future<void> main() async {
  final archive = Archive();
  final timestamp = DateTime.utc(2026, 10, 25).millisecondsSinceEpoch ~/ 1000;
  void add(String name, List<int> bytes) {
    archive.addFile(
      ArchiveFile(name, bytes.length, bytes)
        ..creationTime = timestamp
        ..lastModTime = timestamp,
    );
  }

  for (final name in ['skill.json', 'index.js', 'service.json', 'README.md']) {
    final bytes = await File('agent_examples/yy-tts/$name').readAsBytes();
    add(name, bytes);
  }
  final license = await File('LICENSE').readAsBytes();
  add('LICENSE', license);
  final bytes = ZipEncoder().encode(archive);
  final bundle = AgentPackageBundle.decode(bytes);
  if (bundle.manifest['id'] != 'yy-tts') throw StateError('Wrong package ID');
  final version = bundle.manifest['version'];
  if (version is! String || !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
    throw StateError('Invalid package version');
  }
  final directory = Directory('dist/agent-skills');
  await directory.create(recursive: true);
  final file = File('${directory.path}/skills-yy-tts-v$version.zip');
  if (await file.exists()) {
    if (sha256.convert(await file.readAsBytes()).toString() !=
        sha256.convert(bytes).toString()) {
      throw StateError(
        'Package exists with different bytes; use a new version',
      );
    }
  } else {
    await file.writeAsBytes(bytes, flush: true);
  }
  stdout.writeln(
    jsonEncode({
      'file': file.absolute.path,
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'voices': (bundle.manifest['configSchema']['character']['values'] as List)
          .length,
    }),
  );
}
