import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/bot_client.dart';
import '../../services/ip_whitelist_service.dart';
import '../screens/browser_screen.dart';

class IpWhitelistDialog extends StatefulWidget {
  final IpWhitelistProblem problem;
  final PublicIpService? lookup;
  final Future<void> Function(String)? openSettings;
  final bool trackBotProblem;
  const IpWhitelistDialog({
    super.key,
    required this.problem,
    this.lookup,
    this.openSettings,
    this.trackBotProblem = true,
  });
  @override
  State<IpWhitelistDialog> createState() => _IpWhitelistDialogState();
}

class _IpWhitelistDialogState extends State<IpWhitelistDialog> {
  late final PublicIpService _lookup = widget.lookup ?? PublicIpService();
  List<String> _ips = [];
  bool _loading = false, _copied = false, _closing = false;
  @override
  void initState() {
    super.initState();
    final reported = validPublicIp(widget.problem.sourceIp);
    if (reported != null) {
      _ips = [reported];
    } else {
      unawaited(_query());
    }
  }

  Future<void> _query() async {
    setState(() {
      _loading = true;
      _ips = [];
      _copied = false;
    });
    final ips = await _lookup.lookup();
    if (mounted) {
      setState(() {
        _ips = ips;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    if (widget.lookup == null) _lookup.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: _ips.join('\n')));
      if (mounted) setState(() => _copied = true);
    } catch (_) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('无法复制'),
          content: const Text('请长按 IP 地址选择复制。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bot = context.watch<BotClient?>();
    if (widget.trackBotProblem &&
        bot != null &&
        !identical(bot.ipWhitelistProblem, widget.problem) &&
        !_closing) {
      _closing = true;
      final route = ModalRoute.of(context);
      final navigator = Navigator.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && route?.isActive == true) navigator.removeRoute(route!);
      });
    }
    return AlertDialog(
      title: const Text('接口访问源 IP 不在白名单'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText('机器人 AppID：${widget.problem.appId}'),
              const SizedBox(height: 16),
              Text(
                widget.problem.sourceIp != null
                    ? 'QQ 接口返回的源 IP'
                    : '当前查询到的公网出口 IP',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (_loading)
                const Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('正在查询…'),
                  ],
                ),
              for (final ip in _ips)
                SelectableText(
                  ip,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (!_loading && _ips.isEmpty)
                const Text('暂时无法查询公网 IP。请检查网络后重试，或核对 QQ 接口实际使用的公网出口。'),
              Wrap(
                spacing: 8,
                children: [
                  if (_ips.isNotEmpty)
                    TextButton.icon(
                      onPressed: _copy,
                      icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
                      label: Text(_copied ? '已复制 IP' : '复制 IP'),
                    ),
                  if (widget.problem.sourceIp == null)
                    TextButton(
                      onPressed: _loading ? null : _query,
                      child: const Text('重新查询'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '1. 打开下方对应机器人的开发设置。\n2. 在「IP 白名单」添加实际公网出口 IP 并保存。\n3. 等设置生效后，返回应用重新连接。',
              ),
              const SizedBox(height: 12),
              const Text(
                '使用代理、VPN 或自定义 API 地址时，查询结果可能与 QQ 接口的实际出口不同。不要填写 127.0.0.1、192.168 等局域网地址，也不要为排错放行整个网段。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 12),
              SelectableText(
                widget.problem.settingsUri.toString(),
                style: const TextStyle(fontSize: 12),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('查看接口错误', style: TextStyle(fontSize: 12)),
                children: [SelectableText(widget.problem.message)],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('稍后设置'),
        ),
        FilledButton(
          onPressed: () => widget.openSettings != null
              ? widget.openSettings!(widget.problem.settingsUri.toString())
              : openInAppBrowser(
                  context,
                  widget.problem.settingsUri.toString(),
                ),
          child: const Text('前往开发设置'),
        ),
      ],
    );
  }
}
