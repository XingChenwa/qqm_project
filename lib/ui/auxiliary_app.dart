import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../models/message.dart';
import '../models/received_message.dart';
import '../services/auxiliary_windows.dart';
import 'screens/archive_window_screen.dart';
import 'screens/browser_screen.dart';
import 'screens/forwarded_record_screen.dart';
import 'themes/app_theme.dart';

Future<Widget> initializeAuxiliaryApplication(
  void Function(String) report,
) async {
  report('打开独立窗口');
  final windows = AuxiliaryWindows();
  final request = await windows.consume(AuxiliaryWindows.pendingRequest!);
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: '${request['title'] ?? 'QQ机器人管理器'}',
      size: request['kind'] == 'browser'
          ? const Size(1100, 800)
          : const Size(820, 850),
      minimumSize: const Size(420, 420),
      center: true,
      titleBarStyle: TitleBarStyle.normal,
      skipTaskbar: false,
    ),
  );
  await windowManager.setPreventClose(false);
  await windowManager.show();
  await windowManager.focus();
  void close() {
    windowManager.close();
  }

  final Widget page;
  switch (request['kind']) {
    case 'browser':
      final uri = browserUri(request['url']?.toString() ?? '');
      if (uri == null) throw const FormatException('浏览器链接无效');
      page = BrowserScreen(
        uri: uri,
        onClose: close,
        initialVideo: request['video'] == true,
        filename: request['filename']?.toString() ?? '',
      );
    case 'record':
      page = ForwardedRecordScreen(
        body: ReceivedMessageBody.fromMap(
          Map<String, dynamic>.from(request['body'] as Map),
        ),
        onClose: close,
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
      );
    default:
      throw const FormatException('独立窗口类型无效');
  }
  return Provider<AuxiliaryWindows>.value(
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
      home: page,
    ),
  );
}
