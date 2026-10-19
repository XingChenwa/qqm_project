import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/constants.dart';

typedef ApplicationInitializer =
    Future<Widget> Function(void Function(String) report);

String startupDiagnostic(String stage, Object error, StackTrace? stack) {
  // Exception.toString() may contain broken config JSON, including secrets.
  // Only export the type and stack location, never config values or arguments.
  final frames = (stack?.toString() ?? '')
      .split('\n')
      .take(8)
      .join('\n')
      .replaceAll(RegExp(r'[A-Za-z]:[\\/][^\s)]+'), '<本地路径>');
  var platform = '';
  if (error is PlatformException) {
    final code = RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(error.code)
        ? error.code
        : '未知（已隐藏原始值）';
    final channel = RegExp(
      r'dev\.flutter\.pigeon\.(?:shared_preferences_android|path_provider_android)\.[A-Za-z0-9_.]+',
    ).firstMatch(error.message ?? '')?.group(0);
    platform =
        '\n平台错误码：$code${channel == null ? '' : '\n平台通道：$channel'}\n原始异常正文与 details 已隐藏，避免泄露本地配置。';
  }
  return 'QQ机器人管理器 ${AppConstants.appVersion}+${AppConstants.appBuild}\n'
      '平台：${defaultTargetPlatform.name}\n阶段：$stage\n异常类型：${error.runtimeType}$platform\n$frames';
}

class StartupGate extends StatefulWidget {
  final ApplicationInitializer initialize;
  final Duration timeout;
  const StartupGate({
    super.key,
    required this.initialize,
    this.timeout = const Duration(seconds: 60),
  });
  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  String _stage = '正在启动';
  String? _failure;
  Widget? _application;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _start() async {
    if (!mounted) return;
    try {
      final app = await Future<Widget>.sync(
        () => widget.initialize((stage) {
          if (mounted && _failure == null) setState(() => _stage = stage);
        }),
      ).timeout(widget.timeout);
      if (mounted) setState(() => _application = app);
    } catch (error, stack) {
      final report = startupDiagnostic(_stage, error, stack);
      debugPrint(report);
      if (mounted) setState(() => _failure = report);
    }
  }

  @override
  Widget build(BuildContext context) =>
      _application ??
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xff3366ff),
          useMaterial3: true,
        ),
        home: _failure != null
            ? StartupFailureView(report: _failure!)
            : Scaffold(
                backgroundColor: const Color(0xfff4f7ff),
                body: SafeArea(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.smart_toy_outlined,
                            size: 52,
                            color: Color(0xff3366ff),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'QQ机器人管理器',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 28),
                          const SizedBox(
                            width: 220,
                            child: LinearProgressIndicator(),
                          ),
                          const SizedBox(height: 16),
                          Text(_stage, textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      );
}

class StartupFailureView extends StatefulWidget {
  final String report, title;
  const StartupFailureView({
    super.key,
    required this.report,
    this.title = '启动未完成',
  });
  @override
  State<StartupFailureView> createState() => _StartupFailureViewState();
}

class _StartupFailureViewState extends State<StartupFailureView> {
  String _copyLabel = '复制诊断信息';
  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Material(
      color: const Color(0xfff4f7ff),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 44,
                    color: Color(0xffb42318),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '应用初始化或界面加载出现异常。本地配置和聊天记录不会被自动删除。\n请复制诊断信息反馈，并尝试关闭后重新打开应用。',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  SelectableText(
                    widget.report,
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    icon: const Icon(Icons.copy),
                    label: Text(_copyLabel),
                    onPressed: () async {
                      try {
                        await Clipboard.setData(
                          ClipboardData(text: widget.report),
                        );
                        if (mounted) setState(() => _copyLabel = '已复制诊断信息');
                      } catch (_) {
                        if (mounted) setState(() => _copyLabel = '复制失败，请截图反馈');
                      }
                    },
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
