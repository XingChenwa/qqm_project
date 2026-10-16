import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/qq_qr_login_service.dart';
import '../../utils/platforms.dart';
import 'app_dialogs.dart';

class QqQrLoginPanel extends StatefulWidget {
  final Future<bool> Function(QrBotCredentials credentials) onConfirm;
  final QqQrLoginService Function()? serviceFactory;
  final bool enabled;
  const QqQrLoginPanel({
    super.key,
    required this.onConfirm,
    this.serviceFactory,
    this.enabled = true,
  });

  @override
  State<QqQrLoginPanel> createState() => _QqQrLoginPanelState();
}

class _QqQrLoginPanelState extends State<QqQrLoginPanel>
    with WidgetsBindingObserver {
  late final QqQrLoginService _service;
  bool _saving = false;
  QrLoginPhase? _notified;
  Uri? _previewedCode;
  final _codeKey = GlobalKey();
  final _actionsKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _service = widget.serviceFactory?.call() ?? QqQrLoginService();
    _service.addListener(_updated);
    WidgetsBinding.instance.addObserver(this);
  }

  void _updated() {
    if (!mounted) return;
    setState(() {});
    final newCode = _service.qrUri;
    final codeChanged = newCode != null && newCode != _previewedCode;
    final authorized =
        _service.phase == QrLoginPhase.authorized &&
        _notified != _service.phase;
    if (codeChanged || authorized) {
      _previewedCode = newCode;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final target = (authorized ? _actionsKey : _codeKey).currentContext;
        if (target != null) {
          Scrollable.ensureVisible(
            target,
            alignment: .15,
            duration: const Duration(milliseconds: 200),
          );
        }
      });
    }
    if (_service.phase == QrLoginPhase.failed && _notified != _service.phase) {
      AppDialogs.show(context, _service.message, title: '扫码连接失败', error: true);
    }
    _notified = _service.phase;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _service.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.removeListener(_updated);
    _service.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final credentials = _service.credentials;
    if (_saving || credentials == null) return;
    setState(() => _saving = true);
    try {
      if (await widget.onConfirm(credentials) && mounted) _service.markSaved();
    } catch (_) {
      if (mounted) AppDialogs.show(context, '保存或连接失败，请重试。', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyLink() async {
    final uri = _service.qrUri;
    if (uri == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: uri.toString()));
      if (mounted) AppDialogs.show(context, '已复制腾讯授权链接。请勿公开分享，可在自己的手机 QQ 中打开。');
    } catch (_) {
      if (mounted) AppDialogs.show(context, '复制失败，请使用另一台设备扫码。', error: true);
    }
  }

  Future<void> _openOfficialPage() async {
    final uri = _service.qrUri;
    if (uri == null || uri.scheme != 'https' || uri.host != 'q.qq.com') return;
    // This explicit authentication action may leave the app to complete QQ approval.
    // Ordinary chat/document links still use the built-in browser.
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('Unable to open the official authorization page');
      }
    } catch (_) {
      if (mounted) {
        AppDialogs.show(context, '无法打开授权页，可复制链接到手机 QQ，或用另一台设备扫码。', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = _service.phase;
    final busy = _saving || !widget.enabled;
    final code = _service.qrUri;
    final authorized = phase == QrLoginPhase.authorized;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '用手机 QQ 扫码并确认，自动获取当前机器人的 AppID 和密钥。不是个人 QQ 账号登录。',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 14),
        if (code != null)
          Center(
            child: Container(
              key: _codeKey,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 224),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: QrImageView(
                    data: code.toString(),
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    backgroundColor: Colors.white,
                    semanticsLabel: '腾讯官方机器人授权二维码，请勿公开分享',
                  ),
                ),
              ),
            ),
          )
        else
          Center(
            child: Container(
              width: 140,
              height: 120,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(14),
              ),
              child: phase == QrLoginPhase.creating
                  ? const CircularProgressIndicator()
                  : Icon(
                      authorized || phase == QrLoginPhase.saved
                          ? Icons.verified_user_outlined
                          : Icons.qr_code_2_rounded,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary,
                    ),
            ),
          ),
        const SizedBox(height: 14),
        Semantics(
          liveRegion: true,
          child: Text(
            _service.message,
            key: const ValueKey('qr-login-status'),
            style: const TextStyle(fontSize: 13),
          ),
        ),
        if (authorized) ...[
          const SizedBox(height: 8),
          Text(
            '机器人 AppID：${_service.credentials!.appId}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(height: 14),
        Wrap(
          key: _actionsKey,
          spacing: 10,
          runSpacing: 10,
          children: [
            if (authorized)
              FilledButton.icon(
                onPressed: busy ? null : _confirm,
                icon: const Icon(Icons.login_rounded, size: 18),
                label: Text(_saving ? '正在保存并连接…' : '保存并连接'),
              )
            else
              FilledButton.icon(
                onPressed: busy || phase == QrLoginPhase.creating
                    ? null
                    : () => unawaited(_service.start()),
                icon: const Icon(Icons.qr_code_rounded, size: 18),
                label: Text(
                  code != null ||
                          phase == QrLoginPhase.expired ||
                          phase == QrLoginPhase.failed
                      ? '重新生成二维码'
                      : '生成登录二维码',
                ),
              ),
            if (_service.active || authorized)
              OutlinedButton(
                onPressed: busy ? null : _service.cancel,
                child: const Text('取消本次授权等待'),
              ),
            if (code != null) ...[
              TextButton(
                onPressed: busy ? null : _copyLink,
                child: const Text('复制授权链接'),
              ),
              if (isMobilePlatform)
                TextButton(
                  onPressed: busy ? null : _openOfficialPage,
                  child: const Text('打开官方授权页'),
                ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          isMobilePlatform
              ? '同一部手机可打开官方授权页，按提示进入 QQ，再返回本应用；也可复制链接到自己的 QQ 或用另一台设备扫码。'
              : '仅与腾讯官方服务通信，二维码在本机生成；请勿公开二维码。若平台不允许扫码，切换到“手动配置”。',
          style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
        ),
      ],
    );
  }
}
