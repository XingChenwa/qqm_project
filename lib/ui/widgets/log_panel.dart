import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'app_dialogs.dart';
import 'package:flutter/services.dart';

String logExportText(Iterable<String> logs) => logs.join('\r\n');
Uint8List logExportBytes(Iterable<String> logs) =>
    Uint8List.fromList([0xef, 0xbb, 0xbf, ...utf8.encode(logExportText(logs))]);

enum LogSeverity { info, success, warning, error }

LogSeverity logSeverity(String line) {
  // Ignore the timestamp and classify errors first, including failed successes.
  if (RegExp(r'失败|错误|异常|拒绝|ERROR|FATAL', caseSensitive: false).hasMatch(line)) {
    return LogSeverity.error;
  }
  if (RegExp(r'警告|超时|断开|重连|跳过|限制|WARN', caseSensitive: false).hasMatch(line)) {
    return LogSeverity.warning;
  }
  if (RegExp(
    r'成功|已连接|已发送|已保存|完成鉴权|在线|READY|SUCCESS',
    caseSensitive: false,
  ).hasMatch(line)) {
    return LogSeverity.success;
  }
  return LogSeverity.info;
}

Color logSeverityColor(
  LogSeverity level, {
  required bool dark,
}) => switch (level) {
  LogSeverity.error => dark ? const Color(0xFFFF8A91) : const Color(0xFFBA2634),
  LogSeverity.warning =>
    dark ? const Color(0xFFFFCA80) : const Color(0xFF935600),
  LogSeverity.success =>
    dark ? const Color(0xFF77DBAA) : const Color(0xFF117548),
  LogSeverity.info => dark ? const Color(0xFF9FBFEF) : const Color(0xFF365B89),
};

class LogPanel extends StatelessWidget {
  final List<String> logs;
  const LogPanel({super.key, required this.logs});

  void _notice(BuildContext context, String text) {
    if (context.mounted) {
      AppDialogs.show(context, text);
    }
  }

  Future<void> _copy(BuildContext context) async {
    try {
      await Clipboard.setData(
        ClipboardData(text: logExportText(List<String>.of(logs))),
      );
      if (context.mounted) _notice(context, '全部日志已复制（从早到晚）');
    } catch (_) {
      if (context.mounted) _notice(context, '复制失败，请检查剪贴板是否可用');
    }
  }

  Future<void> _export(BuildContext context, String extension) async {
    final snapshot = List<String>.of(logs);
    final stamp = DateTime.now()
        .toIso8601String()
        .split('.')
        .first
        .replaceAll(RegExp(r'[:T]'), '-');
    try {
      final result = await FilePicker.saveFile(
        dialogTitle: '导出全部日志',
        fileName: 'qqbot-$stamp.$extension',
        type: FileType.custom,
        allowedExtensions: [extension],
        bytes: logExportBytes(snapshot),
      );
      if (context.mounted && result != null) {
        _notice(context, '已导出 ${snapshot.length} 条日志');
      }
    } catch (_) {
      if (context.mounted) _notice(context, '日志导出失败，请选择有写入权限的位置');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '本次运行 · ${logs.length} 条',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: '复制全部日志',
              onPressed: logs.isEmpty ? null : () => _copy(context),
              icon: const Icon(Icons.copy_all_outlined),
            ),
            PopupMenuButton<String>(
              tooltip: '导出全部日志',
              enabled: logs.isNotEmpty,
              icon: const Icon(Icons.file_download_outlined),
              onSelected: (value) => _export(context, value),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'txt', child: Text('导出为 TXT')),
                PopupMenuItem(value: 'log', child: Text('导出为 LOG')),
              ],
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      if (logs.length >= 10000)
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('为控制内存占用，仅保留最近 10,000 条日志。'),
        ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text('导出前请检查日志中是否包含个人信息。', style: TextStyle(fontSize: 11)),
      ),
      Expanded(
        child: logs.isEmpty
            ? const Center(child: Text('暂无日志，连接和收发消息后会显示在这里。'))
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  final log = logs[logs.length - index - 1];
                  final level = logSeverity(log);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SelectableText(
                      log,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        fontFamily: 'Consolas',
                        fontFamilyFallback: const [
                          'Microsoft YaHei',
                          'PingFang SC',
                          'Noto Sans CJK SC',
                          'sans-serif',
                        ],
                        color: logSeverityColor(
                          level,
                          dark: Theme.of(context).brightness == Brightness.dark,
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );
}
