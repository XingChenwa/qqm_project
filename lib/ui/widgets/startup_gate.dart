import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/constants.dart';
import '../../runtime/android_preferences_store.dart';
import 'app_logo.dart';

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
  String platformDiagnostic(Object error) {
    if (error is MissingPluginException) return '\n平台错误码：missing-plugin';
    if (error is! PlatformException) return '\n异常类别：${error.runtimeType}';
    // Arbitrary platform codes may also contain local values. Only known SDK
    // transport/storage error codes are safe to disclose.
    const codes = {
      'PlatformException',
      'channel-error',
      'missing-plugin',
      'null-error',
      'storage_error',
      'StorageError',
      'PREFERENCES_EMPTY_REPLY',
      'PREFERENCES_INVALID_LIST',
      'PREFERENCES_READ_FAILED',
      'PREFERENCES_WRITE_FAILED',
    };
    final code = codes.contains(error.code) ? error.code : '其他平台错误（原值已隐藏）';
    final channel = RegExp(
      r'dev\.flutter\.pigeon\.(?:shared_preferences_android\.(?:SharedPreferencesApi|LegacySharedPreferencesApi)\.(?:getAll|clear|remove|setBool|setInt|setDouble|setString|setEncodedStringList)|path_provider_android\.PathProviderApi\.(?:getTemporaryPath|getApplicationSupportPath|getApplicationDocumentsPath|getApplicationCachePath|getExternalStoragePath))\b',
    ).firstMatch(error.message ?? '')?.group(0);
    final details = error.details;
    final cause = details is Map ? details['cause'] : null;
    const causes = {
      'IOException',
      'SecurityException',
      'IllegalArgumentException',
      'ClassCastException',
      'NumberFormatException',
      'RuntimeException',
      'NativeException',
    };
    return '\n平台错误码：$code${channel == null ? '' : '\n平台通道：$channel'}'
        '${causes.contains(cause) ? '\n原生异常类别：$cause' : ''}';
  }

  final platform = error is PreferenceInitializationException
      ? '\n偏好设置恢复：原通道与备用通道均未完成（数据未清除）'
            '\n原通道：${platformDiagnostic(error.primary)}'
            '\n备用通道：${platformDiagnostic(error.fallback)}'
      : platformDiagnostic(error);
  return 'QQ机器人管理器 ${AppConstants.appVersion}+${AppConstants.appBuild}\n'
      '平台：${defaultTargetPlatform.name}\n阶段：$stage\n异常类型：${error.runtimeType}$platform\n'
      '原始异常正文与参数已隐藏，避免泄露本地配置。\n${frames.isEmpty ? '堆栈：平台未提供' : frames}';
}

class StartupGate extends StatefulWidget {
  final ApplicationInitializer initialize;
  final Duration timeout;
  final Duration minimumDisplay;
  final bool showBranding;
  const StartupGate({
    super.key,
    required this.initialize,
    this.timeout = const Duration(seconds: 60),
    this.minimumDisplay = const Duration(seconds: 5),
    this.showBranding = true,
  });
  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate>
    with SingleTickerProviderStateMixin {
  String _stage = '正在启动';
  String? _failure;
  Widget? _application;
  Widget? _readyApplication;
  late final AnimationController _brandAnimation;
  @override
  void initState() {
    super.initState();
    _brandAnimation =
        AnimationController(
          vsync: this,
          duration: widget.minimumDisplay,
          // This controller also keeps time for the skippable branding screen.
          // Reduced-motion preferences should not shorten its display duration.
          animationBehavior: AnimationBehavior.preserve,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() => _application = _readyApplication);
          }
        });
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
      if (!mounted) return;
      if (!widget.showBranding || widget.minimumDisplay <= Duration.zero) {
        setState(() => _application = app);
      } else {
        setState(() => _readyApplication = app);
        _brandAnimation.forward();
      }
    } catch (error, stack) {
      final report = startupDiagnostic(_stage, error, stack);
      debugPrint(report);
      if (mounted) setState(() => _failure = report);
    }
  }

  @override
  void dispose() {
    _brandAnimation.dispose();
    super.dispose();
  }

  void _skipBranding() {
    if (_readyApplication == null) return;
    _brandAnimation.stop();
    setState(() => _application = _readyApplication);
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
                  child: _readyApplication == null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'QQ机器人管理器',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                const CircularProgressIndicator(),
                                const SizedBox(height: 18),
                                Text(_stage, textAlign: TextAlign.center),
                              ],
                            ),
                          ),
                        )
                      : AnimatedBuilder(
                          animation: _brandAnimation,
                          builder: (context, _) => _brand(context),
                        ),
                ),
              ),
      );

  Widget _brand(BuildContext context) {
    final progress = _brandAnimation.value;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    double entrance(double delay) => reduceMotion
        ? 1
        : Curves.easeOutCubic.transform(
            ((progress - delay) / .24).clamp(0.0, 1.0),
          );
    Widget enter(
      Widget child, {
      required String name,
      bool fromRight = false,
      double delay = 0,
    }) {
      final value = entrance(delay);
      return Opacity(
        key: ValueKey('$name-opacity'),
        opacity: value,
        child: Transform.translate(
          key: ValueKey('$name-slide'),
          offset: Offset((1 - value) * (fromRight ? 52 : -52), 0),
          child: child,
        ),
      );
    }

    Widget pair({
      required String name,
      required Widget left,
      required Widget right,
      required TextStyle style,
      required double delay,
    }) => DefaultTextStyle(
      style: style,
      textAlign: TextAlign.center,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        runSpacing: 2,
        children: [
          enter(left, name: '$name-left', delay: delay),
          enter(right, name: '$name-right', fromRight: true, delay: delay),
        ],
      ),
    );

    final remaining =
        (widget.minimumDisplay.inMilliseconds * (1 - progress) / 1000).ceil();
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 80, 24, 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 660),
              child: Column(
                key: const ValueKey('startup-branding'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity: entrance(0),
                    child: const AppLogo(size: 104),
                  ),
                  const SizedBox(height: 24),
                  Opacity(
                    opacity: entrance(.02),
                    child: const Text(
                      'QQ机器人管理器',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  pair(
                    name: 'startup-description',
                    left: const Text('基于 QQ 官方开放平台的'),
                    right: const Text('跨平台中文机器人管理客户端'),
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.7,
                      color: Color(0xff526581),
                    ),
                    delay: .06,
                  ),
                  const SizedBox(height: 34),
                  pair(
                    name: 'startup-star',
                    left: const Text('如果喜欢这个项目，可以'),
                    right: const Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: '去Github仓库 点个 '),
                          TextSpan(
                            text: 'Star 谢谢喵。',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.7,
                      color: Color(0xff526581),
                    ),
                    delay: .12,
                  ),
                  const SizedBox(height: 12),
                  pair(
                    name: 'startup-repository',
                    left: const Text('仓库地址：'),
                    right: const Text('设置-关于'),
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.7,
                      color: Color(0xff718096),
                    ),
                    delay: .18,
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: 12,
          right: 16,
          child: TextButton(
            key: const ValueKey('startup-skip'),
            onPressed: _skipBranding,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xff526581),
              backgroundColor: Colors.white.withValues(alpha: .8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('跳过'),
                const SizedBox(width: 8),
                Text('${remaining}s', style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      ],
    );
  }
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
