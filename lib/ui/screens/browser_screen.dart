import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/app_dialogs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../utils/browser_policy.dart';
import '../../utils/platforms.dart';

Uri? browserUri(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
          const {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri
      : null;
}

Future<void> openInAppBrowser(BuildContext context, String url) async {
  final uri = browserUri(url);
  if (uri == null) {
    AppDialogs.show(context, '仅支持在应用内打开 HTTP / HTTPS 网页链接');
    return;
  }
  await Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => BrowserScreen(uri: uri)));
}

class BrowserScreen extends StatefulWidget {
  final Uri uri;
  const BrowserScreen({super.key, required this.uri});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  InAppWebViewController? _controller;
  WebViewEnvironment? _environment;
  late String _url = widget.uri.toString();
  String _title = '内置浏览器';
  String? _error;
  bool _ready = false;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _mobileMode = true;
  bool _modeChanging = false;
  String _desktopUserAgent = '';
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      if (!(Platform.isWindows ||
          Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS)) {
        throw const FormatException('当前系统暂不支持内置浏览器，可复制链接。');
      }
      if (InAppWebViewPlatform.instance == null) {
        throw const FormatException('内置浏览器组件未初始化，请完整解压应用并重新启动。可先复制链接。');
      }
      if (Platform.isWindows) {
        final browserVersion = await WebViewEnvironment.getAvailableVersion();
        if (browserVersion == null) {
          throw const FormatException(
            '缺少 Microsoft Edge WebView2 Runtime，请安装后重新打开链接。链接不会自动跳到外部浏览器。',
          );
        }
        final directory = await getApplicationSupportDirectory();
        _environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: path.join(directory.path, 'browser'),
          ),
        );
        // WebView2 has no preferredContentMode support. Other platforms use
        // their native mobile content mode and native browser identity.
        _desktopUserAgent = windowsDesktopUserAgent(browserVersion);
        try {
          final agent = await InAppWebViewController.getDefaultUserAgent();
          if (agent.trim().isNotEmpty) _desktopUserAgent = agent;
        } catch (_) {
          // A missing UA helper must not prevent browsing.
        }
      }
      if (mounted) {
        setState(() => _ready = true);
      } else {
        await _environment?.dispose();
        _environment = null;
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message.toString()
              : '内置浏览器初始化失败，请检查 WebView 组件后重试。',
        );
      }
    }
  }

  @override
  void dispose() {
    // Release the environment after the native view has detached.
    final environment = _environment;
    if (environment != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await environment.dispose();
      });
    }
    super.dispose();
  }

  Future<void> _history(InAppWebViewController controller) async {
    final back = await controller.canGoBack();
    final forward = await controller.canGoForward();
    if (mounted) {
      setState(() {
        _canGoBack = back;
        _canGoForward = forward;
      });
    }
  }

  Future<void> _openExternal(String url) async {
    final uri = externalAppUri(url);
    if (uri == null || !mounted) return;
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        AppDialogs.show(context, '没有找到可以打开此链接的应用');
      }
    } catch (_) {
      if (mounted) AppDialogs.show(context, '没有找到可以打开此链接的应用');
    }
  }

  Future<void> _retry() async {
    setState(() => _error = null);
    if (!_ready) {
      await _prepare();
    } else {
      await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(_url)));
    }
  }

  InAppWebViewSettings get _settings => browserSettings(
    platform: defaultTargetPlatform,
    mobile: _mobileMode,
    desktopUserAgent: _desktopUserAgent,
  );

  Future<void> _toggleMode() async {
    if (_modeChanging) return;
    final previousMode = _mobileMode;
    setState(() {
      _mobileMode = !previousMode;
      _modeChanging = true;
    });
    try {
      await _controller?.setSettings(settings: _settings);
      if (mounted) await _controller?.reload();
    } catch (_) {
      if (mounted) {
        setState(() => _mobileMode = previousMode);
        AppDialogs.show(context, '网页模式切换失败，请重试。', error: true);
      }
    } finally {
      if (mounted) setState(() => _modeChanging = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: '关闭内置浏览器',
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: _mobileMode ? '切换为电脑版' : '切换为手机版',
          onPressed: _modeChanging ? null : _toggleMode,
          icon: Icon(
            _mobileMode
                ? Icons.phone_android_outlined
                : Icons.computer_outlined,
          ),
        ),
        IconButton(
          tooltip: '复制链接',
          icon: const Icon(Icons.copy_outlined),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _url));
            if (context.mounted) {
              AppDialogs.show(context, '链接已复制');
            }
          },
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: '后退',
                  onPressed: _canGoBack ? () => _controller?.goBack() : null,
                  icon: const Icon(Icons.arrow_back),
                ),
                IconButton(
                  tooltip: '前进',
                  onPressed: _canGoForward
                      ? () => _controller?.goForward()
                      : null,
                  icon: const Icon(Icons.arrow_forward),
                ),
                IconButton(
                  tooltip: '刷新网页',
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                ),
                Expanded(
                  child: Text(
                    _url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _mobileMode ? '手机版' : '电脑版',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
          if (_progress < 1 && _error == null)
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          Expanded(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Center(
                child: ConstrainedBox(
                  key: const ValueKey('browser-viewport'),
                  constraints: BoxConstraints(
                    maxWidth: _mobileMode && isDesktopPlatform
                        ? 430
                        : double.infinity,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_ready)
                        InAppWebView(
                          webViewEnvironment: _environment,
                          initialUrlRequest: URLRequest(
                            url: WebUri.uri(widget.uri),
                          ),
                          initialSettings: _settings,
                          onWebViewCreated: (controller) =>
                              _controller = controller,
                          shouldOverrideUrlLoading: (controller, action) async {
                            final url = action.request.url?.toString() ?? '';
                            if (browserUri(url) != null ||
                                (action.isForMainFrame == false &&
                                    url == 'about:blank')) {
                              return NavigationActionPolicy.ALLOW;
                            }
                            if (externalAppUri(url) != null) {
                              await _openExternal(url);
                            }
                            return NavigationActionPolicy.CANCEL;
                          },
                          onCreateWindow: (controller, action) async {
                            final url = action.request.url?.toString() ?? '';
                            if (browserUri(url) != null) {
                              await controller.loadUrl(
                                urlRequest: URLRequest(url: WebUri(url)),
                              );
                            } else if (externalAppUri(url) != null) {
                              await _openExternal(url);
                            }
                            return false;
                          },
                          onLoadStart: (_, url) {
                            if (mounted) {
                              setState(() {
                                _error = null;
                                _progress = 0;
                                if (url != null) _url = url.toString();
                              });
                            }
                          },
                          onLoadStop: (controller, url) async {
                            if (mounted) {
                              setState(() {
                                _progress = 1;
                                if (url != null) _url = url.toString();
                              });
                            }
                            await _history(controller);
                          },
                          onUpdateVisitedHistory: (controller, url, _) async {
                            if (mounted && url != null) {
                              setState(() => _url = url.toString());
                            }
                            await _history(controller);
                          },
                          onProgressChanged: (_, progress) {
                            if (mounted) {
                              setState(() => _progress = progress / 100);
                            }
                          },
                          onTitleChanged: (_, title) {
                            if (mounted) {
                              setState(
                                () => _title = title?.trim().isNotEmpty == true
                                    ? title!
                                    : '内置浏览器',
                              );
                            }
                          },
                          onReceivedError: (_, request, error) {
                            if (mounted && request.isForMainFrame == true) {
                              setState(() => _error = '网页加载失败，请检查网络或链接是否过期。');
                            }
                          },
                          onReceivedHttpError: (_, request, response) {
                            if (mounted &&
                                request.isForMainFrame == true &&
                                (response.statusCode ?? 0) >= 400) {
                              setState(
                                () => _error =
                                    '网页返回 HTTP ${response.statusCode}，请检查链接是否过期。',
                              );
                            }
                          },
                          onDownloadStartRequest: (_, request) async {
                            final url = request.url.toString();
                            if (externalAppUri(url) != null) {
                              await _openExternal(url);
                            }
                          },
                        ),
                      if (_error != null)
                        ColoredBox(
                          color: Theme.of(context).colorScheme.surface,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.public_off_outlined,
                                    size: 44,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(_error!, textAlign: TextAlign.center),
                                  const SizedBox(height: 16),
                                  OutlinedButton.icon(
                                    onPressed: _retry,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('重试'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
