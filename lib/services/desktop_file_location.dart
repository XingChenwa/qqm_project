import 'dart:io';
import 'package:path/path.dart' as p;

/// Open a known local file/folder without passing paths through a shell.
class DesktopFileLocation {
  static bool get supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  static Future<void> open(
    String path, {
    bool selectFile = false,
    Future<ProcessResult> Function(String, List<String>)? run,
    String? system,
  }) async {
    final absolute = p.normalize(p.absolute(path));
    if (!await FileSystemEntity.isDirectory(absolute) &&
        !await FileSystemEntity.isFile(absolute)) {
      throw const FileSystemException('文件或目录不存在');
    }
    final platform = system ?? Platform.operatingSystem;
    final (program, arguments) = switch (platform) {
      'windows' => (
        'explorer.exe',
        [selectFile ? '/select,$absolute' : absolute],
      ),
      'macos' => ('/usr/bin/open', [if (selectFile) '-R', absolute]),
      'linux' => ('xdg-open', [selectFile ? p.dirname(absolute) : absolute]),
      _ => throw const FileSystemException('此平台不支持系统文件管理器'),
    };
    final result =
        await (run ?? (executable, args) => Process.run(executable, args))(
          program,
          arguments,
        );
    // Explorer can return 1 after successfully delegating to its existing process.
    if (result.exitCode != 0 &&
        !(platform == 'windows' && result.exitCode == 1)) {
      throw const FileSystemException('系统文件管理器未能打开');
    }
  }
}
