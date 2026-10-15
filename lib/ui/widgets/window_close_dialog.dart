import 'package:flutter/material.dart';

import '../../services/desktop_window_controller.dart';

class WindowCloseDialog extends StatefulWidget {
  const WindowCloseDialog({super.key});

  @override
  State<WindowCloseDialog> createState() => _WindowCloseDialogState();
}

class _WindowCloseDialogState extends State<WindowCloseDialog> {
  bool _remember = false;

  void _choose(bool hideToTray) => Navigator.pop(
    context,
    DesktopCloseDecision(hideToTray: hideToTray, remember: _remember),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: Icon(
      Icons.desktop_windows_outlined,
      color: Theme.of(context).colorScheme.primary,
      size: 30,
    ),
    title: const Text('关闭窗口'),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('隐藏到系统托盘后，机器人会继续运行。\n退出程序则会断开连接并停止回复。'),
          const SizedBox(height: 16),
          CheckboxListTile(
            key: const ValueKey('remember-close-choice'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('以后不再显示，记住本次选择'),
            subtitle: const Text('可在设置的「桌面窗口」中更改'),
            value: _remember,
            onChanged: (value) => setState(() => _remember = value ?? false),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('cancel-window-close'),
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      OutlinedButton(
        key: const ValueKey('exit-from-close-dialog'),
        onPressed: () => _choose(false),
        child: const Text('退出程序'),
      ),
      FilledButton.icon(
        key: const ValueKey('hide-from-close-dialog'),
        onPressed: () => _choose(true),
        icon: const Icon(Icons.minimize_rounded, size: 18),
        label: const Text('隐藏到托盘'),
      ),
    ],
  );
}
