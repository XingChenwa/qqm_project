import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/mobile_connection.dart';
import 'app_dialogs.dart';

class MobileConnectionCard extends StatelessWidget {
  const MobileConnectionCard({super.key});
  @override
  Widget build(BuildContext context) {
    final connection = context.watch<MobileConnection?>();
    if (connection == null || !connection.supported) {
      return const SizedBox.shrink();
    }
    Future<void> open({bool battery = false}) async {
      try {
        await connection.openSettings(battery: battery);
      } catch (_) {
        if (context.mounted) {
          await AppDialogs.show(context, '请在系统设置中打开 QQ机器人管理器的应用设置。');
        }
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '后台连接',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            if (connection.android) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('允许后台保持机器人连接'),
                subtitle: Text(
                  connection.running
                      ? '保活服务已启动，通知栏会显示运行状态'
                      : '连接后显示常驻通知，增加耗电；不会开启自启动或修改系统电池设置。',
                ),
                value: connection.enabled,
                onChanged: connection.busy
                    ? null
                    : (value) async {
                        try {
                          await connection.setEnabled(value);
                        } catch (_) {
                          if (context.mounted) {
                            await AppDialogs.show(
                              context,
                              '后台连接设置未能保存，请重试。',
                              error: true,
                            );
                          }
                        }
                      },
              ),
              const Text(
                '如果切到后台仍断线：允许应用通知，将电池使用设为“不受限制”，在厂商设置中允许后台运行／自启动，并锁定最近任务。不同手机菜单名称可能不同。手动划掉应用或强制停止后不会继续连接。',
                style: TextStyle(fontSize: 13, height: 1.6),
              ),
            ] else ...[
              const Text(
                'iOS 会挂起普通应用的后台网络连接，无法靠“后台刷新”保证机器人一直在线。回到前台后会自动检查并恢复连接；要长期在线，建议让电脑或 Linux 服务端运行机器人。',
                style: TextStyle(fontSize: 13, height: 1.6),
              ),
            ],
            if (connection.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  connection.error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => open(),
                  icon: const Icon(Icons.settings_outlined, size: 17),
                  label: const Text('系统应用设置'),
                ),
                if (connection.android)
                  TextButton(
                    onPressed: () => open(battery: true),
                    child: const Text('电池优化设置'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
