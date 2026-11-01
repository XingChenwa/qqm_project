import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../services/data_migration_service.dart';
import '../../services/desktop_window_controller.dart';
import '../../utils/constants.dart';
import '../widgets/app_dialogs.dart';

Future<void> saveMigrationZip(
  BuildContext context,
  Uint8List bytes,
  String filename,
) async {
  final chosen = await FilePicker.saveFile(
    dialogTitle: '保存完整数据备份',
    fileName: filename,
    type: FileType.custom,
    allowedExtensions: ['zip'],
    bytes: bytes,
  );
  if (chosen == null) return;
  if (!(Platform.isAndroid || Platform.isIOS)) {
    await File(chosen).writeAsBytes(bytes, flush: true);
  }
  if (context.mounted) {
    await AppDialogs.show(context, '完整ZIP已保存。备份包含机器人密钥、模型Key和聊天记录，请妥善保管。');
  }
}

class DataMigrationScreen extends StatefulWidget {
  final DataMigrationService service;
  const DataMigrationScreen({super.key, required this.service});
  @override
  State<DataMigrationScreen> createState() => _DataMigrationScreenState();
}

class _DataMigrationScreenState extends State<DataMigrationScreen> {
  String? _error;
  bool _working = false;
  Future<void> _run(Future<void> Function() task) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await task();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message.toString()
              : '数据迁移未完成，请检查文件、目录权限和磁盘空间；原始备份不会删除。',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _export() => _run(() async {
    final bytes = await widget.service.exportZip();
    if (!mounted) return;
    await saveMigrationZip(
      context,
      bytes,
      'qqbotmanager-backup-v${AppConstants.appVersion}-build${AppConstants.appBuild}-${DateTime.now().millisecondsSinceEpoch}.zip',
    );
  });
  Future<void> _import([File? recovery]) => _run(() async {
    File? file = recovery;
    if (file == null) {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        withData: false,
      );
      final path = result?.files.single.path;
      if (path == null) return;
      file = File(path);
    }
    final bytes = await widget.service.readZip(file),
        data = await widget.service.inspectZip(bytes);
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('恢复完整数据？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '来源版本：${data.metadata['appVersion'] ?? '未知'} + ${data.metadata['appBuild'] ?? ''}',
              ),
              Text('创建时间：${data.metadata['createdAt'] ?? '未知'}'),
              const SizedBox(height: 12),
              Text(
                '原工作区：${data.counts['messages']} 条消息 · ${data.counts['sessions']} 个会话',
              ),
              Text(
                'QQ Agent：${data.counts['agentConnections']} 个连接 · ${data.counts['agentExtensions']} 个插件/Skill',
              ),
              Text('插件工作区：${data.counts['workspaceFiles']} 个文件'),
              if ((data.counts['nodePluginFiles'] ?? 0) > 0)
                Text(
                  '原版 Node 插件：${data.counts['nodePluginFiles']} 个源码与数据文件；恢复后请安装依赖。',
                ),
              Text('自定义表情图片：${data.counts['localMediaFiles']} 个文件'),
              const SizedBox(height: 12),
              const Text(
                '将完整替换两个工作区的应用数据，包括配置、密钥、聊天、插件/Skill及运行数据。恢复前会自动保存当前完整备份；重启后应用。请先保存正在编辑的文件，并只恢复你信任的备份。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('备份当前数据并恢复'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.service.stageRestore(bytes);
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.service,
    builder: (context, _) {
      if (widget.service.restartRequired) {
        return MigrationRestartScreen(service: widget.service);
      }
      final disabled = _working || widget.service.busy;
      return PopScope(
        canPop: !disabled,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('数据迁移'),
            automaticallyImplyLeading: !disabled,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.inventory_2_outlined, size: 48),
                    const SizedBox(height: 14),
                    const Text(
                      '一个 ZIP，迁移全部应用数据',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '包括原机器人工作台与 QQ Agent 的所有账号、密钥、模型、人设、聊天记录、插件和 Skill 源文件、配置、记忆、提醒、收藏、用量，以及插件工作区和历史文件。',
                    ),
                    const SizedBox(height: 8),
                    const Text('云端素材仍归对应机器人所有；独立部署的翻唱服务、音色模型和系统组件需在新设备另行准备。'),
                    const SizedBox(height: 22),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.icon(
                          onPressed: disabled ? null : _export,
                          icon: const Icon(Icons.archive_outlined),
                          label: const Text('导出完整 ZIP'),
                        ),
                        OutlinedButton.icon(
                          onPressed: disabled ? null : () => _import(),
                          icon: const Icon(Icons.restore_page_outlined),
                          label: const Text('导入 ZIP 恢复'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (disabled) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 10),
                      Text(
                        widget.service.stage.isEmpty
                            ? '正在处理备份…'
                            : widget.service.stage,
                      ),
                    ],
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const Divider(height: 36),
                    const Text(
                      '恢复前自动备份',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    FutureBuilder<List<File>>(
                      future: widget.service.recoveryBackups(),
                      builder: (context, snapshot) {
                        final files = snapshot.data ?? [];
                        if (files.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Text('执行恢复后，这里会保留恢复前的完整备份。'),
                          );
                        }
                        return Column(
                          children: [
                            for (final file in files)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  p.basename(file.path),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Wrap(
                                  children: [
                                    IconButton(
                                      tooltip: '导出这份备份',
                                      onPressed: disabled
                                          ? null
                                          : () => _run(() async {
                                              final bytes = await widget.service
                                                  .readZip(file);
                                              if (context.mounted) {
                                                await saveMigrationZip(
                                                  context,
                                                  bytes,
                                                  p.basename(file.path),
                                                );
                                              }
                                            }),
                                      icon: const Icon(Icons.download_outlined),
                                    ),
                                    IconButton(
                                      tooltip: '恢复这份备份',
                                      onPressed: disabled
                                          ? null
                                          : () => _import(file),
                                      icon: const Icon(Icons.restore),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class MigrationRestartScreen extends StatelessWidget {
  final DataMigrationService service;
  const MigrationRestartScreen({super.key, required this.service});
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.restart_alt_rounded, size: 64),
                  const SizedBox(height: 18),
                  const Text(
                    '重启后恢复完整数据',
                    style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '备份已校验，机器人连接和插件任务已暂停。请完全退出应用后重新打开；手机端请从最近任务中关闭后再打开。',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  SelectableText(
                    '恢复前备份：\n${service.recoveryPath}',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  if (context.read<DesktopWindowController?>() != null)
                    FilledButton(
                      onPressed: () =>
                          context.read<DesktopWindowController>().exitApp(),
                      child: const Text('退出应用'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
