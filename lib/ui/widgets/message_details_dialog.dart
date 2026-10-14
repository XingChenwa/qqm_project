import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/message.dart';
import '../../models/received_message.dart';

Future<void> showMessageDetails(BuildContext context, MessageModel message) {
  final text = const JsonEncoder.withIndent('  ').convert(
    redactMessageDetails({
      '事件': message.extra?['eventType'] ?? '',
      '消息 ID': message.id,
      '群/用户 OpenID': message.sessionId,
      '原始消息类型': message.sourceMessageType,
      '引用索引': message.referenceIndex,
      '原始事件': message.rawEvent,
    }),
  );
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('消息详情'),
      content: SizedBox(
        width: math.min(760, MediaQuery.sizeOf(context).width * 0.86),
        height: math.min(540, MediaQuery.sizeOf(context).height * 0.65),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '鉴权令牌等敏感字段已隐藏。原始附件、卡片和嵌套元素保留在本地记录中。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('已复制脱敏后的消息详情')));
            }
          },
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: const Text('复制详情'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
