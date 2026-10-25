import 'dart:convert';
import 'store.dart';
import 'http.dart';
import 'js_packages.dart';
import 'models.dart';

/// Offline native ABI / ESM check for the headless distribution containers.
Future<void> verifyAgentEngine() async {
  final store = AgentStore.memory();
  await store.open();
  final http = AgentHttp();
  final packages = AgentJsPackages(store, http);
  try {
    final result = await packages.run(
      manifest: {
        'id': 'engine_check',
        'name': 'Engine check',
        'entry': 'index.js',
        'packageManifest': {'apiVersion': 1},
        'files': {
          'index.js': base64Encode(
            utf8.encode(
              "import fs from 'node:fs';export function setup(api){api.registerTool({id:'check',name:'check',parameters:{type:'object',properties:{}},execute(){fs.writeFileSync('/data/check','QuickJS ESM OK');return {content:fs.readFileSync('/data/check','utf8')};}})}",
            ),
          ),
        },
      },
      settings: {},
      operation: 'tool',
      args: {'id': 'check'},
      active: () => true,
    );
    if (result['content'] != 'QuickJS ESM OK') {
      throw const AgentException('内嵌引擎自检失败。');
    }
  } finally {
    await packages.drain();
    http.close();
    await store.close();
  }
}
