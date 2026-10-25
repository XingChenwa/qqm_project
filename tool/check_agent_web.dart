import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/web.dart';

/// Explicit public-network smoke test; no saved accounts, keys or chat records.
Future<void> main(List<String> args) async {
  final http = AgentHttp();
  try {
    final result = await AgentWeb(
      http,
    ).search(args.isEmpty ? 'QQ机器人 官方文档' : args.join(' '), CancelToken());
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  } catch (e) {
    stderr.writeln('公开 Bing 搜索检查未通过：$e');
    exitCode = 1;
  } finally {
    http.close();
  }
}
