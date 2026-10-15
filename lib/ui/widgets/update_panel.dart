import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_update_service.dart';
import '../../services/desktop_window_controller.dart';
import '../../utils/constants.dart';
import 'app_dialogs.dart';

Future<void> showUpdateDialog(
  BuildContext context, {
  bool check = false,
}) async {
  final updates = context.read<AppUpdateService?>();
  if (updates == null) {
    await AppDialogs.show(context, '当前运行环境未初始化更新服务');
    return;
  }
  final desktop = context.read<DesktopWindowController?>();
  final dialog = AppDialogs.present<void>(
    context,
    key: 'software-update',
    builder: (_) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AppUpdateService>.value(value: updates),
        Provider<DesktopWindowController?>.value(value: desktop),
      ],
      child: const _UpdateDialog(),
    ),
  );
  if (check) unawaited(updates.check());
  await dialog;
  if (updates.hasUpdate) updates.dismiss();
}

class UpdatePanel extends StatelessWidget {
  const UpdatePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final updates = context.watch<AppUpdateService?>();
    if (updates == null) return const Center(child: Text('当前运行环境未初始化更新服务'));
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('软件更新', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 10),
                const Text(
                  '当前版本 ${AppConstants.appVersion}（构建 ${AppConstants.appBuild}）',
                ),
                const SizedBox(height: 8),
                Text(
                  updates.configured
                      ? '启动时发现新版会弹窗提醒。下载前验证签名，安装前校验 SHA-256。'
                      : '更新服务尚未配置，发布者需在构建时内置更新公钥。',
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => showUpdateDialog(context, check: true),
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(updates.hasUpdate ? '查看新版与安装进度' : '检查更新'),
                ),
                if (updates.platform == 'windows')
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动下载 Windows 更新'),
                    subtitle: const Text('不会强制中断机器人，由你选择重启更新。'),
                    value: updates.preferences.autoDownload,
                    onChanged: updates.setAutoDownload,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog();

  Future<void> _install(BuildContext context, AppUpdateService updates) async {
    final desktop = context.read<DesktopWindowController?>();
    if (updates.platform == 'windows') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('重启并更新？'),
          content: const Text('会先保存本地聊天并断开机器人，再替换软件文件；失败时尝试恢复备份。请先关闭其他同目录实例。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('立即更新'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await updates.install(exitForUpdate: desktop?.exitApp);
  }

  @override
  Widget build(BuildContext context) {
    final updates = context.watch<AppUpdateService>();
    final release = updates.release;
    final phase = updates.phase;
    final size = MediaQuery.sizeOf(context);
    final windows = updates.platform == 'windows';
    final installLabel = switch (updates.platform) {
      'windows' => '重启并更新',
      'android' => '开始安装 APK',
      'macos' => '打开安装包',
      _ => '导出 IPA / 用全能签打开',
    };
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 600,
        height: math.min(
          640,
          math.max(
            200,
            size.height - MediaQuery.viewInsetsOf(context).bottom - 48,
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.system_update_alt),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      updates.hasUpdate ? '发现新版本' : '软件更新',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭更新',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    '当前版本 ${AppConstants.appVersion}（构建 ${AppConstants.appBuild}）',
                  ),
                  const SizedBox(height: 16),
                  if (!updates.configured)
                    const Text('更新服务尚未配置，暂时无法检查更新。')
                  else if (!updates.hasUpdate &&
                      !updates.busy &&
                      updates.error.isEmpty)
                    const Text('当前已是最新版本。'),
                  if (updates.hasUpdate && release != null) ...[
                    Text(
                      '最新版本 ${release.version}（${release.build}）',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      release.notes.isEmpty ? '新版本已发布，可下载后安装。' : release.notes,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${(release.size / 1048576).toStringAsFixed(1)} MB · ${release.format.toUpperCase()} · 签名已验证',
                    ),
                  ],
                  if (updates.busy) ...[
                    const SizedBox(height: 20),
                    LinearProgressIndicator(
                      value: phase == UpdatePhase.downloading
                          ? updates.progress
                          : null,
                    ),
                    const SizedBox(height: 10),
                    Text(switch (phase) {
                      UpdatePhase.downloading =>
                        '正在下载 ${(updates.progress * 100).toStringAsFixed(0)}%',
                      UpdatePhase.installing => '正在打开安装程序…',
                      _ => '正在检查更新…',
                    }),
                  ],
                  if (phase == UpdatePhase.ready) ...[
                    const SizedBox(height: 16),
                    const Text('安装包已下载，SHA-256 校验通过。'),
                  ],
                  if (updates.error.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    SelectableText(
                      updates.error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(switch (updates.platform) {
                    'windows' => '确认后才重启安装，稍后关闭此弹窗不影响后台下载。',
                    'android' => '安装需系统确认，新 APK 签名须与旧版一致；不会自动卸载旧版。',
                    'macos' => '打开 DMG 后，将应用拖入“应用程序”替换旧版；替换前请退出管理器。',
                    _ => 'IPA 需适用于设备的有效证书重签；下载或导出成功不代表已经安装。',
                  }),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(updates.hasUpdate ? '稍后' : '关闭'),
                  ),
                  OutlinedButton.icon(
                    onPressed: updates.configured && !updates.busy
                        ? updates.check
                        : null,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重新检查'),
                  ),
                  if (updates.hasUpdate)
                    FilledButton.icon(
                      onPressed: updates.busy
                          ? null
                          : phase == UpdatePhase.ready
                          ? () => _install(context, updates)
                          : updates.download,
                      icon: Icon(
                        phase == UpdatePhase.ready
                            ? windows
                                  ? Icons.restart_alt
                                  : Icons.open_in_new
                            : Icons.download,
                        size: 18,
                      ),
                      label: Text(
                        phase == UpdatePhase.ready ? installLabel : '下载新版',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class UpdateNotice extends StatefulWidget {
  final Widget child;
  final BuildContext Function()? dialogContext;
  const UpdateNotice({super.key, required this.child, this.dialogContext});
  @override
  State<UpdateNotice> createState() => _UpdateNoticeState();
}

class _UpdateNoticeState extends State<UpdateNotice> {
  // A fresh process reminds again; timer checks never repeat the same build.
  final _promptedBuilds = <int>{};

  @override
  Widget build(BuildContext context) {
    final updates = context.watch<AppUpdateService?>();
    final release = updates?.release;
    if (updates != null &&
        updates.hasUpdate &&
        release != null &&
        updates.dismissedBuild != release.build &&
        _promptedBuilds.add(release.build)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !updates.hasUpdate ||
            updates.dismissedBuild == release.build) {
          return;
        }
        showUpdateDialog(widget.dialogContext?.call() ?? context);
      });
    }
    return widget.child;
  }
}
