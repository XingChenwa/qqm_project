import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'data_backup_archive.dart';

class NodePluginBackup {
  /// Original source + per-bot changes/data. Native npm modules and the managed
  /// Node/browser runtimes must be installed for the destination OS, not copied.
  static Future<Map<String, Uint8List>> collect(
    Directory directory, {
    required int maxBytes,
    required int maxEntries,
  }) async {
    if (!await directory.exists()) return {};
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('原版插件根目录不能是链接。');
    }
    final root = await directory.resolveSymbolicLinks();
    final paths = <String>[];
    Future<void> visit(Directory dir) async {
      await for (final entity in dir.list(followLinks: false)) {
        final relative = p
            .relative(entity.path, from: directory.path)
            .replaceAll('\\', '/');
        final parts = relative.split('/');
        if (['host', 'runtime', 'staging', 'removed'].contains(parts.first) ||
            parts.any(
              (s) => [
                'node_modules',
                '.git',
                '.cache',
                'temp',
                'logs',
                '.prepared',
                '.prepared-files.json',
              ].contains(s),
            )) {
          continue;
        }
        if (parts.first != 'packages' && relative != 'connection.json') {
          continue;
        }
        if (await FileSystemEntity.type(entity.path, followLinks: false) ==
                FileSystemEntityType.link ||
            !p.isWithin(root, await entity.resolveSymbolicLinks()) ||
            !DataBackupArchive.safePath(relative)) {
          throw const FormatException('原版插件目录包含链接或无效路径，请处理后再完整备份。');
        }
        if (entity is Directory) {
          await visit(entity);
        } else if (entity is File) {
          paths.add(relative);
        }
        if (paths.length > 20000) throw const FormatException('原版插件数据文件过多。');
      }
    }

    await visit(directory);
    paths.sort((a, b) {
      final aSource = a.split('/').elementAtOrNull(2) == 'source';
      final bSource = b.split('/').elementAtOrNull(2) == 'source';
      return aSource != bSource ? (aSource ? -1 : 1) : a.compareTo(b);
    });
    final result = <String, Uint8List>{};
    var size = 0;
    for (final relative in paths) {
      final file = File(p.joinAll([directory.path, ...relative.split('/')]));
      final before = await file.stat();
      if (before.size > DataBackupArchive.maxEntryBytes) {
        throw const FormatException('原版插件存在过大的数据文件。');
      }
      final bytes = await file.readAsBytes();
      final after = await file.stat();
      if (before.modified != after.modified || before.size != after.size) {
        throw const FormatException('原版插件文件仍在变化，请停止插件后重试。');
      }
      final parts = relative.split('/');
      if (parts.length > 6 && parts[2] == 'accounts' && parts[4] == 'plugins') {
        final original =
            result[[
              'packages',
              parts[1],
              'source',
              ...parts.skip(6),
            ].join('/')];
        if (original != null &&
            original.length == bytes.length &&
            sha256.convert(original) == sha256.convert(bytes)) {
          continue;
        }
      }
      size += bytes.length;
      if (size > maxBytes || result.length >= maxEntries) {
        throw const FormatException('原版插件超出完整备份的文件数或大小限制。');
      }
      result[relative] = bytes;
    }
    return result;
  }
}
