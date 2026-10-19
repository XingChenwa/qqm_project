import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

bool isIpWhitelistError(String message) {
  final normalized = message.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  return normalized.contains('ip') &&
      ((normalized.contains('白名单') &&
              (normalized.contains('不在') ||
                  normalized.contains('未在') ||
                  normalized.contains('未加入'))) ||
          ((normalized.contains('whitelist') ||
                  normalized.contains('allowlist')) &&
              (normalized.contains('not') || normalized.contains('denied'))));
}

String? validPublicIp(String? value) {
  if (value == null || value.length > 64 || value.contains('%')) return null;
  final ip = InternetAddress.tryParse(value.trim());
  if (ip == null || ip.isLoopback || ip.isLinkLocal || ip.isMulticast) {
    return null;
  }
  final bytes = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    if (bytes[0] == 0 ||
        bytes[0] == 10 ||
        bytes[0] == 127 ||
        bytes[0] >= 224 ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127)) {
      return null;
    }
  } else {
    // Reject unspecified, unique-local and mapped private IPv4 addresses.
    if (bytes.every((byte) => byte == 0) || (bytes[0] & 0xfe) == 0xfc) {
      return null;
    }
    if (bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return validPublicIp(bytes.skip(12).join('.'));
    }
  }
  return ip.address;
}

String? reportedSourceIp(dynamic data) {
  if (data is Map) {
    for (final key in [
      'source_ip',
      'sourceIp',
      'client_ip',
      'clientIp',
      'ip',
    ]) {
      final found = validPublicIp(data[key]?.toString());
      if (found != null) return found;
    }
    return reportedSourceIp(data['message'] ?? data['msg'] ?? data['error']);
  }
  if (data is! String || data.length > 8192) return null;
  // Only a labelled IP is meaningful; do not mistake a trace ID for an address.
  final match = RegExp(
    r'(?:source[_ ]?ip|client[_ ]?ip|源\s*ip|来源\s*ip|ip)\s*[：:=\[]\s*\[?([0-9a-fA-F:.]+)',
    caseSensitive: false,
  ).firstMatch(data);
  return validPublicIp(match?.group(1));
}

class IpWhitelistProblem {
  final String appId, message;
  final String? sourceIp;
  const IpWhitelistProblem({
    required this.appId,
    required this.message,
    this.sourceIp,
  });

  Uri get settingsUri => Uri(
    scheme: 'https',
    host: 'q.qq.com',
    pathSegments: ['qqbot', 'dashboard', 'manage', appId],
    queryParameters: {'sec': 'dev-settings'},
  );
}

/// On-demand diagnosis only. This client never receives QQ credentials, bot
/// identifiers, chat content or device information, and does not store results.
class PublicIpService {
  static const endpoints = [
    'https://myip.ipip.net',
    'https://ipv4.icanhazip.com',
    'https://api.ipify.org',
  ];
  final Dio _http;
  PublicIpService({Dio? http})
    : _http =
          http ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 4),
              receiveTimeout: const Duration(seconds: 4),
              followRedirects: false,
            ),
          );
  Future<List<String>> lookup() async {
    // Prefer the reachable domestic provider, with independent fallbacks.
    // A failed/invalid response must never silently become an IPv6 result.
    for (final endpoint in endpoints) {
      final ip = await _lookup(endpoint, InternetAddressType.IPv4);
      if (ip != null) return [ip];
    }
    return [];
  }

  Future<String?> _lookup(String endpoint, InternetAddressType family) async {
    final cancel = CancelToken();
    try {
      return await (() async {
        final response = await _http.get<ResponseBody>(
          endpoint,
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
            headers: {'Authorization': null, 'Cookie': null},
            validateStatus: (status) => status == 200,
          ),
        );
        final bytes = BytesBuilder(copy: false);
        if (response.data == null) return null;
        await for (final chunk in response.data!.stream.timeout(
          const Duration(seconds: 4),
        )) {
          if (bytes.length + chunk.length > 256) return null;
          bytes.add(chunk);
        }
        final text = utf8.decode(bytes.takeBytes()).trim();
        final labelled = Uri.parse(endpoint).host == 'myip.ipip.net'
            ? RegExp(
                r'^当前\s*IP[：:]\s*((?:\d{1,3}\.){3}\d{1,3})(?=\s|$)',
                caseSensitive: false,
              ).firstMatch(text)?.group(1)
            : null;
        final ip = validPublicIp(labelled ?? text);
        return ip != null && InternetAddress(ip).type == family ? ip : null;
      })().timeout(
        const Duration(seconds: 6),
        onTimeout: () {
          cancel.cancel('diagnostic timeout');
          return null;
        },
      );
    } catch (_) {
      return null;
    }
  }

  void dispose() => _http.close(force: true);
}
