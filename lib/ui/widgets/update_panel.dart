import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_update_service.dart';
import '../../services/desktop_window_controller.dart';
import '../../utils/constants.dart';

class UpdatePanel extends StatelessWidget {
  const UpdatePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final updates = context.watch<AppUpdateService?>();
    if (updates == null) return const Center(child: Text('当前运行环境未初始化更新服务'));
    final release = updates.release;
    final phase = updates.phase;
    final windows = updates.platform == 'windows';
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
                      ? '每次启动发现新版都会提醒；运行中每5分钟检查。校验签名和安装包 SHA-256。'
                      : '更新服务尚未启用：发布者需要部署后台并在构建时内置 UPDATE_PUBLIC_KEY。不会自动信任网站返回的公钥。',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: updates.configured && !updates.busy
                          ? updates.check
                          : null,
                      icon: const Icon(Icons.refresh),
                      label: Text(
                        phase == UpdatePhase.checking ? '检查中…' : '检查更新',
                      ),
                    ),
                    if (updates.hasUpdate && phase != UpdatePhase.ready)
                      FilledButton.icon(
                        onPressed: updates.busy ? null : updates.download,
                        icon: const Icon(Icons.download),
                        label: const Text('下载新版'),
                      ),
                    if (phase == UpdatePhase.ready)
                      FilledButton.icon(
                        onPressed: () => _install(context, updates),
                        icon: Icon(
                          windows
                              ? Icons.restart_alt
                              : updates.platform == 'android'
                              ? Icons.install_mobile
                              : Icons.ios_share,
                        ),
                        label: Text(
                          windows
                              ? '重启并更新'
                              : updates.platform == 'android'
                              ? '开始安装 APK'
                              : '导出 IPA / 用全能签打开',
                        ),
                      ),
                  ],
                ),
                if (updates.busy) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: phase == UpdatePhase.downloading
                        ? updates.progress
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    phase == UpdatePhase.downloading
                        ? '正在下载 ${(updates.progress * 100).toStringAsFixed(0)}%'
                        : phase == UpdatePhase.installing
                        ? '准备更新中，请勿关闭电脑…'
                        : '正在检查更新…',
                  ),
                ],
                if (release != null) ...[
                  const SizedBox(height: 16),
                  Text('最新版本 ${release.version}（${release.build}）'),
                  const SizedBox(height: 8),
                  SelectableText(
                    release.notes.isEmpty ? '暂无补充更新说明' : release.notes,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '安装包 ${(release.size / 1048576).toStringAsFixed(1)} MB · ${release.format.toUpperCase()}',
                  ),
                ],
                if (updates.error.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    updates.error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (windows)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动下载 Windows 更新'),
                    subtitle: const Text('不会强制中断机器人；由你选择重启更新。'),
                    value: updates.preferences.autoDownload,
                    onChanged: updates.setAutoDownload,
                  ),
                if (updates.platform == 'android')
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Android 会请求允许安装并显示系统确认。新 APK 的包名和签名必须与当前应用一致；签名不同不会自动卸载旧版。',
                    ),
                  ),
                if (updates.platform == 'ios')
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'iOS 不允许应用自行安装未签名 IPA。可在这里下载并导出到全能签，使用适用于设备的合法有效证书重签；导出成功不代表安装成功。',
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  title: const Text('参与软件使用统计'),
                  subtitle: const Text(
                    '首次安装默认开启；已关闭的用户保持关闭。发送设备名称／型号、系统版本、架构、软件版本和来源 IP。',
                  ),
                  value: updates.preferences.usageConsent,
                  onChanged: updates.setUsageConsent,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Text(
                    updates.usageStatus.isEmpty
                        ? '启动后自动登记，每分钟更新心跳。关闭会停止上报并请求删除记录。'
                        : updates.usageStatus,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    '统计发送至 botmanager.uuze.cn，用于设备活跃和版本分布。电脑名称可能包含你设置的姓名；不希望发送时可关闭。'
                    '不读取 QQ 凭据、聊天、文件内容、硬件序列号、MAC 或广告标识。'
                    'IP 默认保留7天，失活设备及设备资料默认90天清理。',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _install(BuildContext context, AppUpdateService updates) async {
    final desktop = context.read<DesktopWindowController?>();
    if (updates.platform == 'windows') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重启并更新？'),
          content: const Text(
            '会先保存本地聊天并断开机器人连接，再替换软件文件。替换失败将尝试恢复备份。其他仍运行的同目录实例可能阻止更新。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('立即更新'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await updates.install(exitForUpdate: desktop?.exitApp);
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
  // Session-only: a fresh launch always reminds again, even for the same build.
  final Set<int> _promptedBuilds = {};
  bool _dialogOpen = false;

  Future<void> _showPanel(BuildContext target) => showModalBottomSheet<void>(
    context: target,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => SizedBox(
      height: MediaQuery.sizeOf(context).height * .85,
      child: const UpdatePanel(),
    ),
  );

  void _schedulePrompt(AppUpdateService updates) {
    final release = updates.release;
    if (!updates.hasUpdate ||
        release == null ||
        _dialogOpen ||
        updates.dismissedBuild == release.build ||
        !_promptedBuilds.add(release.build)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          !updates.hasUpdate ||
          updates.dismissedBuild == release.build) {
        return;
      }
      final target = widget.dialogContext?.call() ?? context;
      _dialogOpen = true;
      try {
        final view = await showDialog<bool>(
          context: target,
          builder: (dialog) => AlertDialog(
            title: const Text('发现新版本'),
            content: SingleChildScrollView(
              child: Text(
                'QQ机器人管理器 ${release.version}（${release.build}）\n\n'
                '${release.notes.isEmpty ? '新版本已发布，可下载后安装。' : String.fromCharCodes(release.notes.runes.take(600))}',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('稍后'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('查看新版'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (view == false) updates.dismiss();
        if (view == true && target.mounted) await _showPanel(target);
      } finally {
        _dialogOpen = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final updates = context.watch<AppUpdateService?>();
    if (updates != null) _schedulePrompt(updates);
    if (updates == null ||
        !updates.hasUpdate ||
        updates.dismissedBuild == updates.release!.build) {
      return widget.child;
    }
    return Overlay.wrap(
      child: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.system_update_alt, size: 19),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '新版 ${updates.release!.version}${updates.phase == UpdatePhase.ready ? ' 已下载' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          _showPanel(widget.dialogContext?.call() ?? context),
                      child: const Text('查看更新'),
                    ),
                    IconButton(
                      tooltip: '稍后提醒',
                      onPressed: updates.dismiss,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(child: widget.child),
        ],
      ),
    );
  }
}
