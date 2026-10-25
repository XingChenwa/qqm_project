import 'dart:convert';
import 'dart:io';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/js_packages.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/package_compatibility.dart';

/// Inspect supplied ZIPs in a temporary in-memory sandbox. Never activates a
/// plugin, sends QQ messages, accesses real account storage or performs HTTP.
Future<void> main(List<String> files) async {
  final store = AgentStore.memory();
  await store.open();
  final http = AgentHttp();
  final runner = AgentJsPackages(store, http);
  try {
    for (final filename in files) {
      AgentExtension? extension;
      try {
        extension = AgentExtension.fromPackage(
          await File(filename).readAsBytes(),
        );
        extension.validate();
        final found = await runner.run(
          manifest: extension.manifest,
          settings: extension.config,
          operation: 'inspect',
          active: () => true,
        );
        stdout.writeln(
          jsonEncode({
            'file': File(filename).uri.pathSegments.last,
            'id': extension.id,
            'loaded': true,
            'tools': (found['tools'] as List? ?? [])
                .map((v) => text(object(v)['id']))
                .toList(),
            'available': found['available'],
            'hooks': found['hooks'],
            'providers': found['providers'],
            'compatibility': packageCompatibility(extension.manifest, found),
          }),
        );
      } catch (error) {
        var reason = error is AgentException
            ? error.message
            : error.runtimeType.toString();
        if (extension != null) {
          for (final v in extension.config.entries.where(
            (v) =>
                object(extension!.configSchema[v.key])['secret'] == true ||
                RegExp(
                  'key|token|cookie|secret',
                  caseSensitive: false,
                ).hasMatch(v.key),
          )) {
            if (v.value is String && (v.value as String).isNotEmpty) {
              reason = reason.replaceAll(v.value as String, '[已隐藏]');
            }
          }
        }
        stdout.writeln(
          jsonEncode({
            'file': File(filename).uri.pathSegments.last,
            'loaded': false,
            'error': reason,
          }),
        );
      }
    }
  } finally {
    http.close();
    await store.close();
  }
}
