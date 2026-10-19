// Explicit diagnostic only. No QQ information or credentials are involved.
import 'dart:io';
import 'package:qq_bot_manager/services/ip_whitelist_service.dart';

Future<void> main() async {
  final service = PublicIpService();
  try {
    final ips = await service.lookup();
    final valid =
        ips.length == 1 &&
        validPublicIp(ips.single) != null &&
        !ips.single.contains(':');
    stdout.writeln(
      valid
          ? 'PASS: IPv4 query succeeded (address not logged).'
          : 'IPv4 lookup unavailable.',
    );
    if (!valid) exitCode = 1;
  } finally {
    service.dispose();
  }
}
