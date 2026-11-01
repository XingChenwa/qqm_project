import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import '../agent/store.dart';
import 'storage_service.dart';

class BackupData {
  final Map<String, dynamic> official;
  final Map<String, String> agent;
  final Map<String, Uint8List> workspace;
  final Map<String, Uint8List> assets;
  final Map<String, Uint8List> agentWorkspace;
  final Map<String, Uint8List> nodeWorkspace;
  final Map<String, dynamic> metadata;
  const BackupData(
    this.official,
    this.agent,
    this.workspace,
    this.metadata, {
    this.assets = const {},
    this.agentWorkspace = const {},
    this.nodeWorkspace = const {},
  });
  Map<String, int> get counts => {
    for (final e in (official['boxes'] as Map).entries)
      e.key.toString(): (e.value as Map).length,
    'agentRecords': agent.length,
    'workspaceFiles': workspace.length,
    'localMediaFiles': assets.length,
    'agentSourceFiles': agentWorkspace.length,
    'nodePluginFiles': nodeWorkspace.length,
    'agentConnections': agent.keys
        .where((k) => k.startsWith('connection:'))
        .length,
    'agentExtensions': agent.keys
        .where((k) => k.startsWith('extension:'))
        .length,
  };
}

/// A logical, cross-platform backup. No ZIP entry is extracted by its name into
/// an arbitrary directory, and open Hive files are never copied into the ZIP.
class DataBackupArchive {
  static const maxZipBytes = 128 * 1024 * 1024;
  static const maxExpandedBytes = 256 * 1024 * 1024;
  static const maxEntryBytes = 128 * 1024 * 1024;
  static const maxEntries = 10000;
  static const format = 'cn.uuze.botmanager.backup';
  static bool safePath(String name) {
    if (name.isEmpty ||
        name.length > 512 ||
        name.contains('\\') ||
        name.startsWith('/') ||
        name.contains(RegExp(r'[\x00-\x1f:<>"|?*]'))) {
      return false;
    }
    return name
        .split('/')
        .every(
          (part) =>
              part.isNotEmpty &&
              part != '.' &&
              part != '..' &&
              !part.endsWith('.') &&
              !part.endsWith(' ') &&
              !RegExp(
                r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                caseSensitive: false,
              ).hasMatch(part),
        );
  }

  static Uint8List encode(BackupData data) {
    StorageService.validateAllData(data.official);
    AgentStore.validateAllData(data.agent);
    final entries = <String, Uint8List>{
      'official.json': Uint8List.fromList(
        utf8.encode(jsonEncode(data.official)),
      ),
      'agent.json': Uint8List.fromList(utf8.encode(jsonEncode(data.agent))),
      for (final e in data.workspace.entries) 'workspace/${e.key}': e.value,
      for (final e in data.assets.entries) 'assets/${e.key}': e.value,
      for (final e in data.agentWorkspace.entries)
        'agent-workspace/${e.key}': e.value,
      for (final e in data.nodeWorkspace.entries)
        'node-workspace/${e.key}': e.value,
    };
    if (entries.length + 1 > maxEntries) {
      throw const FormatException('备份文件数量超过10000个。');
    }
    var total = 0;
    for (final e in entries.entries) {
      if (!safePath(e.key) ||
          e.value.length > maxEntryBytes ||
          (total += e.value.length) > maxExpandedBytes) {
        throw const FormatException('备份文件路径无效或数据超过256MB。');
      }
    }
    final archive = Archive();
    final manifest = {
      ...data.metadata,
      'format': format,
      'schema': 1,
      'counts': data.counts,
      'entries': {
        for (final e in entries.entries)
          e.key: {
            'size': e.value.length,
            'sha256': sha256.convert(e.value).toString(),
          },
      },
    };
    final header = utf8.encode(jsonEncode(manifest));
    archive.addFile(ArchiveFile('manifest.json', header.length, header));
    for (final e in entries.entries) {
      archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    if (bytes.length > maxZipBytes) {
      throw const FormatException('完整备份压缩后超过128MB，请先整理过大的本地数据。');
    }
    return bytes;
  }

  static BackupData decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxZipBytes) {
      throw const FormatException('备份ZIP须在128MB以内。');
    }
    try {
      _preflight(bytes);
      final zip = ZipDecoder().decodeBytes(bytes);
      final entries = <String, ArchiveFile>{};
      final names = <String>{};
      var total = 0;
      for (final file in zip) {
        if (!file.isFile ||
            file.isSymbolicLink ||
            !safePath(file.name) ||
            !names.add(file.name.toLowerCase()) ||
            file.size > maxEntryBytes ||
            (total += file.size) > maxExpandedBytes) {
          throw const FormatException('备份包含无效路径、链接、重复文件或超限内容。');
        }
        entries[file.name] = file;
      }
      final header = entries.remove('manifest.json');
      if (header == null || header.size > 1024 * 1024) {
        throw const FormatException('不是QQ机器人管理器的完整数据备份。');
      }
      final raw = jsonDecode(utf8.decode(header.content as List<int>));
      if (raw is! Map ||
          raw['format'] != format ||
          raw['schema'] != 1 ||
          raw['entries'] is! Map) {
        throw const FormatException('备份格式或版本不受支持。');
      }
      final manifest = Map<String, dynamic>.from(raw),
          declared = raw['entries'] as Map;
      if (declared.length != entries.length ||
          !declared.containsKey('official.json') ||
          !declared.containsKey('agent.json') ||
          entries.keys.any((n) => !declared.containsKey(n))) {
        throw const FormatException('备份内容与清单不一致。');
      }
      final contents = <String, Uint8List>{};
      for (final e in entries.entries) {
        if (e.key != 'official.json' &&
            e.key != 'agent.json' &&
            !e.key.startsWith('workspace/') &&
            !e.key.startsWith('assets/') &&
            !e.key.startsWith('agent-workspace/') &&
            !e.key.startsWith('node-workspace/')) {
          throw const FormatException('备份包含未知的数据区域。');
        }
        final spec = declared[e.key];
        if (spec is! Map || spec['size'] != e.value.size) {
          throw const FormatException('备份文件大小校验失败。');
        }
        final content = Uint8List.fromList(e.value.content as List<int>);
        if (content.length != spec['size'] ||
            sha256.convert(content).toString() != spec['sha256']) {
          throw const FormatException('备份文件校验失败，文件可能已损坏。');
        }
        contents[e.key] = content;
      }
      final official = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(contents.remove('official.json')!)) as Map,
      );
      final agent = Map<String, String>.from(
        jsonDecode(utf8.decode(contents.remove('agent.json')!)) as Map,
      );
      StorageService.validateAllData(official);
      AgentStore.validateAllData(agent);
      final assets = {
        for (final e in contents.entries.where(
          (e) => e.key.startsWith('assets/'),
        ))
          e.key.substring(7): e.value,
      };
      for (final raw in ((official['boxes'] as Map)['emojis'] as Map).values) {
        final emoji = jsonDecode(raw as String) as Map;
        for (final field in ['localPath', 'url']) {
          final value = emoji[field];
          if (value is String &&
              value.startsWith('qqm-backup-asset://') &&
              !assets.containsKey(value.substring(19))) {
            throw const FormatException('自定义表情缺少对应的本地图片文件。');
          }
        }
      }
      return BackupData(
        official,
        agent,
        {
          for (final e in contents.entries.where(
            (e) => e.key.startsWith('workspace/'),
          ))
            e.key.substring(10): e.value,
        },
        manifest,
        assets: assets,
        agentWorkspace: {
          for (final e in contents.entries.where(
            (e) => e.key.startsWith('agent-workspace/'),
          ))
            e.key.substring(16): e.value,
        },
        nodeWorkspace: {
          for (final e in contents.entries.where(
            (e) => e.key.startsWith('node-workspace/'),
          ))
            e.key.substring(15): e.value,
        },
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('备份ZIP格式无效或数据无法读取。');
    }
  }

  static void _preflight(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    int u16(int at) => data.getUint16(at, Endian.little);
    int u32(int at) => data.getUint32(at, Endian.little);
    var end = -1;
    for (
      var at = bytes.length - 22;
      at >= 0 && at >= bytes.length - 65557;
      at--
    ) {
      if (u32(at) == 0x06054b50 && at + 22 + u16(at + 20) == bytes.length) {
        end = at;
        break;
      }
    }
    if (end < 0 ||
        u16(end + 4) != 0 ||
        u16(end + 6) != 0 ||
        u16(end + 8) != u16(end + 10) ||
        u16(end + 10) > maxEntries) {
      throw const FormatException('备份ZIP目录无效。');
    }
    final count = u16(end + 10), offset = u32(end + 16);
    if (count == 65535 || offset + u32(end + 12) != end) {
      throw const FormatException('不支持ZIP64或分卷备份。');
    }
    var at = offset, total = 0;
    for (var i = 0; i < count; i++) {
      if (at + 46 > end ||
          u32(at) != 0x02014b50 ||
          u16(at + 8) & 1 != 0 ||
          !{0, 8}.contains(u16(at + 10))) {
        throw const FormatException('备份ZIP头部无效或使用了不支持的加密/压缩格式。');
      }
      total += u32(at + 24);
      if (u32(at + 24) > maxEntryBytes ||
          total > maxExpandedBytes ||
          u32(at + 20) == 0xffffffff ||
          u32(at + 42) >= offset) {
        throw const FormatException('备份解压后超过大小限制。');
      }
      at += 46 + u16(at + 28) + u16(at + 30) + u16(at + 32);
    }
    if (at != end) throw const FormatException('备份ZIP目录长度不匹配。');
  }
}
