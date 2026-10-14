import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/plugin_manager.dart';
import '../../models/plugin.dart';
import '../themes/app_theme.dart';
import 'weather_config_dialog.dart';

class PluginPanel extends StatelessWidget {
  const PluginPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<PluginManager>();
    final plugins = manager.plugins;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Row(
            children: [
              const Icon(
                Icons.extension_rounded,
                size: 18,
                color: AppTheme.qqBlue,
              ),
              const SizedBox(width: 8),
              const Text(
                '插件',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              _countBadge(
                plugins.where((plugin) => plugin.info.isEnabled).length,
                plugins.length,
              ),
            ],
          ),
        ),
        Expanded(
          child: plugins.isEmpty
              ? _emptyState(context)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  itemCount: plugins.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    return _PluginCard(
                      plugin: plugins[index],
                      manager: manager,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _countBadge(int enabled, int total) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.qqBlue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$enabled / $total',
        style: const TextStyle(
          fontSize: 11,
          color: AppTheme.qqBlue,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.extension_off_rounded,
            size: 42,
            color: Theme.of(context).hintColor.withValues(alpha: 0.45),
          ),
          const SizedBox(height: 10),
          const Text('暂无插件', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            '插件加载后会显示在这里。',
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }
}

class _PluginCard extends StatelessWidget {
  final BotPlugin plugin;
  final PluginManager manager;

  const _PluginCard({required this.plugin, required this.manager});

  PluginInfo get info => plugin.info;

  @override
  Widget build(BuildContext context) {
    final enabled = info.isEnabled;
    final accent = enabled ? AppTheme.qqGreen : Theme.of(context).hintColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(_iconFor(info.id), size: 17, color: accent),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'v${info.version}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: enabled,
                  onChanged: (value) {
                    if (value) {
                      manager.enablePlugin(info.id);
                    } else {
                      manager.disablePlugin(info.id);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              info.description,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _statusChip(enabled),
                for (final permission in info.permissions.take(3))
                  _permissionChip(permission),
                if (info.permissions.length > 3)
                  _permissionChip('+${info.permissions.length - 3}'),
                if (info.id == 'weather_plugin')
                  ActionChip(
                    avatar: const Icon(Icons.settings_rounded, size: 15),
                    label: const Text('配置'),
                    tooltip: '配置高德天气与 IP 查询',
                    onPressed: () => _showWeatherConfig(context),
                    visualDensity: VisualDensity.compact,
                  ),
                if (info.id == 'translate_comment')
                  ActionChip(
                    avatar: const Icon(Icons.settings_rounded, size: 15),
                    label: const Text('配置'),
                    onPressed: () => _showTranslateConfig(context),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String id) {
    return switch (id) {
      'weather_plugin' => Icons.cloud_outlined,
      'dice_plugin' => Icons.casino_outlined,
      'translate_comment' => Icons.translate_rounded,
      'example_plugin' => Icons.smart_toy_outlined,
      _ => Icons.extension_rounded,
    };
  }

  Widget _statusChip(bool enabled) {
    final color = enabled ? AppTheme.qqGreen : AppTheme.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        enabled ? '已启用' : '已停用',
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _permissionChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.qqBlue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          color: AppTheme.qqBlue,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  void _showTranslateConfig(BuildContext context) {
    final apiKeyController = TextEditingController(
      text: info.config['api_key']?.toString() ?? '',
    );
    final langController = TextEditingController(
      text: info.config['target_lang']?.toString() ?? '中文',
    );

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('代码注释翻译配置'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: apiKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'DeepSeek API 密钥',
                  hintText: 'sk-...',
                  helperText: '可在 platform.deepseek.com 获取',
                  prefixIcon: Icon(Icons.key_rounded),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: langController,
                decoration: const InputDecoration(
                  labelText: '目标语言',
                  hintText: '默认：中文',
                  prefixIcon: Icon(Icons.language_rounded),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              manager.updatePluginConfig(info.id, {
                'api_key': apiKeyController.text.trim(),
                'target_lang': langController.text.trim().isEmpty
                    ? '中文'
                    : langController.text.trim(),
              });
              Navigator.pop(dialogContext);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _showWeatherConfig(BuildContext context) async {
    final config = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => WeatherConfigDialog(config: info.config),
    );
    if (config == null) return;
    final saved = await manager.updatePluginConfig(info.id, config);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved ? '高德天气与 IP 查询配置已保存' : '保存失败，请重新打开插件配置')),
    );
  }
}
