// Read-only release signature check. Does not initialize the app, QQ, storage or telemetry.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:qq_bot_manager/models/app_release.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/check_update_server.dart HTTPS_ORIGIN PUBLIC_KEY',
    );
    exitCode = 64;
    return;
  }
  final server = Uri.parse(args[0]);
  if (server.scheme != 'https' ||
      server.host.isEmpty ||
      server.userInfo.isNotEmpty ||
      server.path.replaceAll('/', '').isNotEmpty ||
      server.hasQuery ||
      server.hasFragment ||
      base64Decode(args[1]).length != 32) {
    stderr.writeln(
      'Expected an HTTPS origin and a 32-byte public key, never a private key.',
    );
    exitCode = 64;
    return;
  }
  final random = Random.secure();
  final nonce = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(
      server
          .resolve('/api/v1/update')
          .replace(
            queryParameters: {
              'platform': 'windows',
              'arch': 'x64',
              'nonce': nonce,
            },
          ),
    );
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw HttpException(
        'Update endpoint returned HTTP ${response.statusCode}',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.addAll(chunk);
      if (bytes.length > 100000) {
        throw const FormatException('Update response is too large');
      }
    }
    final release = await AppRelease.verifyEnvelope(
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      publicKey: args[1],
      nonce: nonce,
      platform: 'windows',
      arch: 'x64',
      server: server,
    );
    stdout.writeln(
      release == null
          ? 'Signature verified: server matches this public key; no published Windows release yet.'
          : 'Signature verified: ${release.version}+${release.build}, ${release.format}. No package downloaded or executed.',
    );
  } catch (error) {
    stderr.writeln('Update server check failed: $error');
    exitCode = 1;
  } finally {
    client.close(force: true);
  }
}
