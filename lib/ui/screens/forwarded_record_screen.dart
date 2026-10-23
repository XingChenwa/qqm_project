import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/received_message.dart';
import '../../services/auxiliary_windows.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/received_message_view.dart';

Future<void> openForwardedRecord(
  BuildContext context,
  ReceivedMessageBody body,
) async {
  final windows = context.read<AuxiliaryWindows?>();
  final title = body.recordTitle.isNotEmpty ? body.recordTitle : '聊天记录';
  if (windows?.supported == true) {
    try {
      await windows!.open('record', {
        'title': title,
        'body': body.toDisplayMap(),
        'dark': Theme.of(context).brightness == Brightness.dark,
      });
    } catch (_) {
      if (context.mounted) {
        await AppDialogs.show(context, '独立聊天记录窗口未能打开，请重试。', error: true);
      }
    }
    return;
  }
  if (context.mounted) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => ForwardedRecordScreen(body: body)),
    );
  }
}

/// A QQ-style record reader: sender/optional time, actual message text, and
/// images at their aspect ratio. Raw export URLs stay in message details only.
class ForwardedRecordScreen extends StatelessWidget {
  final ReceivedMessageBody body;
  final VoidCallback? onClose;
  final bool showAppBar;
  const ForwardedRecordScreen({
    super.key,
    required this.body,
    this.onClose,
    this.showAppBar = true,
  });

  @override
  Widget build(BuildContext context) {
    var record = body;
    while (record.elements.length == 1 && record.elements.single.isRecord) {
      record = record.elements.single;
    }
    final rows = record.elements.isEmpty ? [record] : record.elements;
    return Scaffold(
      appBar: !showAppBar
          ? null
          : AppBar(
              leading: IconButton(
                tooltip: onClose == null ? '返回原聊天' : '关闭聊天记录窗口',
                icon: Icon(
                  onClose == null
                      ? Icons.arrow_back_rounded
                      : Icons.close_rounded,
                ),
                onPressed: onClose ?? () => Navigator.pop(context),
              ),
              title: Text(
                record.recordTitle.isNotEmpty ? record.recordTitle : '聊天记录',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView.builder(
              key: const ValueKey('forwarded-record-page'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final item = rows[i];
                final name = item.authorName.isNotEmpty
                    ? item.authorName
                    : record.authorName.isNotEmpty
                    ? record.authorName
                    : '消息发送者';
                final time = item.timestamp?.toLocal();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Column(
                    children: [
                      if (time != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 18),
                          child: Text(
                            '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                        ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ProfileAvatar(
                            name: name,
                            url: item.authorAvatar,
                            radius: 19,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context).hintColor,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                ReceivedMessageView(
                                  body: item,
                                  storageKey: 'record/$i',
                                  inRecord: true,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
