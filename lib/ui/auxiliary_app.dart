import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../models/received_message.dart';
import '../services/auxiliary_windows.dart';
import '../services/auxiliary_window_controller.dart';
import 'screens/archive_window_screen.dart';
import 'screens/browser_screen.dart';
import 'screens/forwarded_record_screen.dart';
import 'themes/app_theme.dart';
import 'widgets/desktop_window_frame.dart';

Future<Widget> initializeAuxiliaryApplication(
  void Function(String) report,
) async {
  report('打开独立窗口');
  final windows = AuxiliaryWindows();
  final request = await windows.consume(AuxiliaryWindows.pendingRequest!);
  final controller = AuxiliaryWindowController();
  final title = request['kind'] == 'history'
      ? '${request['title'] ?? '会话'} · 聊天记录'
      : '${request['title'] ?? 'QQ机器人管理器'}';
  await controller.initialize(
    title: title,
    size: request['kind'] == 'browser'
        ? const Size(1100, 800)
        : const Size(820, 850),
  );
  void close() => controller.requestClose();

  final Widget page;
  switch (request['kind']) {
    case 'browser':
      final uri = browserUri(request['url']?.toString() ?? '');
      if (uri == null) throw const FormatException('浏览器链接无效');
      page = BrowserScreen(
        uri: uri,
        onClose: close,
        showCloseButton: !controller.ready,
        initialVideo: request['video'] == true,
        filename: request['filename']?.toString() ?? '',
      );
    case 'record':
      page = ForwardedRecordScreen(
        body: ReceivedMessageBody.fromMap(
          Map<String, dynamic>.from(request['body'] as Map),
        ),
        onClose: close,
        showAppBar: !controller.ready,
      );
    case 'history':
      page = ArchiveWindowScreen(
        title: request['title']?.toString() ?? '聊天记录',
        messages: (request['messages'] as List)
            .whereType<Map>()
            .map((m) => MessageModel.fromMap(Map<String, dynamic>.from(m)))
            .toList(),
        initialMessageId: request['initialMessageId'] as String?,
        onClose: close,
        showAppBar: !controller.ready,
      );
    default:
      throw const FormatException('独立窗口类型无效');
  }
  return ChangeNotifierProvider<AuxiliaryWindowController>(
    create: (_) => controller,
    lazy: false,
    child: Provider<AuxiliaryWindows>.value(
      value: windows,
      child: MaterialApp(
        title: '${request['title'] ?? 'QQ机器人管理器'}',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: request['dark'] == true ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => DesktopWindowFrame(
          controller: controller,
          title: title,
          showVersion: false,
          closeTooltip: '关闭此窗口',
          child: child!,
        ),
        home: page,
      ),
    ),
  );
}
