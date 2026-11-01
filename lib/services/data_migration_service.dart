import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../runtime/notifier.dart';
import '../agent/store.dart';
import '../utils/constants.dart';
import 'data_backup_archive.dart';
import 'node_plugin_backup.dart';
import 'storage_service.dart';

/// Restore is staged for the next startup, before any bot/plugin is created.
/// A durable journal and a full recovery ZIP protect against partial restores.
class DataMigrationService extends ChangeNotifier {
  final StorageService storage;
  final AgentStore agent;
  final Directory dataRoot, migrationRoot;
  Directory? _workspaceRoot;
  final Future<Directory> Function()? workspaceRootResolver;
  Directory get workspaceRoot =>
      _workspaceRoot ?? (throw StateError('插件工作区目录尚未解析。'));
  Future<Directory> _workspaceDirectory() async =>
      _workspaceRoot ??= await workspaceRootResolver!();
  Future<void> Function()? beforeRestore;
  Future<void> Function()? onStageFailure;
  Future<void> Function()? beforeSnapshot;
  Future<void> Function()? afterSnapshot;
  String? startupNotice;
  bool busy = false, restartRequired = false;
  String stage = '', recoveryPath = '';
  DataMigrationService({
    required this.storage,
    required this.agent,
    required this.dataRoot,
    Directory? workspaceRoot,
    this.workspaceRootResolver,
    this.beforeRestore,
  }) : assert(workspaceRoot != null || workspaceRootResolver != null),
       _workspaceRoot = workspaceRoot,
       migrationRoot = Directory(p.join(dataRoot.path, 'data-migration'));

  Future<void> _directory(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const FormatException('数据目录不能是链接或普通文件。');
    }
    await directory.create(recursive: true);
  }

  void _progress(String value) {
    stage = value;
    notifyListeners();
  }

  Future<BackupData> _snapshot() async {
    final workspaceRoot = await _workspaceDirectory();
    _progress('读取全部机器人、聊天、配置和QQ Agent数据');
    final official = await storage.exportAllData(),
        records = await agent.exportAllData();
    final files = <String, Uint8List>{};
    final assets = <String, Uint8List>{};
    var assetBytes = 0;
    final emojis = (official['boxes'] as Map)['emojis'] as Map;
    for (final key in emojis.keys.toList()) {
      final emoji = Map<String, dynamic>.from(
            jsonDecode(emojis[key] as String) as Map,
          ),
          path = emoji['localPath'];
      if (path is! String || path.isEmpty) continue;
      final file = File(path);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('部分自定义表情的本地图片不存在或是链接，请重新选择图片后再完整备份。');
      }
      final before = await file.stat();
      if (before.size > DataBackupArchive.maxEntryBytes ||
          assetBytes + before.size > DataBackupArchive.maxExpandedBytes ||
          assets.length + 3 >= DataBackupArchive.maxEntries) {
        throw const FormatException('自定义表情图片超出备份大小或数量限制。');
      }
      final bytes = await readZip(file), after = await file.stat();
      if (before.size != after.size || before.modified != after.modified) {
        throw const FormatException('自定义表情图片正在变化，请稍后再试。');
      }
      final ext = p.extension(path).toLowerCase(),
          suffix =
              {
                '.png',
                '.jpg',
                '.jpeg',
                '.gif',
                '.webp',
                '.bmp',
                '.heic',
                '.avif',
              }.contains(ext)
              ? ext
              : '.img';
      final name = 'emojis/${sha256.convert(bytes)}$suffix';
      if (!assets.containsKey(name)) assetBytes += bytes.length;
      assets[name] = bytes;
      emoji['localPath'] = 'qqm-backup-asset://$name';
      if (emoji['url'] == path) emoji['url'] = emoji['localPath'];
      emojis[key] = jsonEncode(emoji);
    }
    var size = assetBytes;
    await _directory(workspaceRoot);
    final root = await workspaceRoot.resolveSymbolicLinks();
    await for (final entity in workspaceRoot.list(
      recursive: true,
      followLinks: false,
    )) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const FormatException('插件工作区包含链接，请移出链接后再完整备份。');
      }
      if (entity is! File) continue;
      final relative = p
          .relative(entity.path, from: workspaceRoot.path)
          .replaceAll('\\', '/');
      if (!DataBackupArchive.safePath(relative) ||
          !p.isWithin(root, await entity.resolveSymbolicLinks())) {
        throw const FormatException('插件工作区文件路径无效。');
      }
      final stat = await entity.stat();
      size += stat.size;
      if (stat.size > DataBackupArchive.maxEntryBytes ||
          size > DataBackupArchive.maxExpandedBytes ||
          files.length + assets.length + 3 >= DataBackupArchive.maxEntries) {
        throw const FormatException('插件工作区超出完整备份的大小或数量限制。');
      }
      final bytes = await readZip(entity), after = await entity.stat();
      if (stat.size != after.size || stat.modified != after.modified) {
        throw const FormatException('插件文件正在被修改，请保存并稍后重试。');
      }
      files[relative] = bytes;
    }
    final agentSources = <String, Uint8List>{};
    final sourceRoot = Directory(p.join(dataRoot.path, 'agent_sources'));
    if (await FileSystemEntity.type(sourceRoot.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await _directory(sourceRoot);
      await for (final entity in sourceRoot.list(
        recursive: true,
        followLinks: false,
      )) {
        if (await FileSystemEntity.type(entity.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw const FormatException('外部源码目录包含链接，请移出后再备份。');
        }
        if (entity is! File) continue;
        final relative = p
            .relative(entity.path, from: sourceRoot.path)
            .replaceAll('\\', '/');
        if (!DataBackupArchive.safePath(relative)) {
          throw const FormatException('外部源码文件路径无效。');
        }
        final before = await entity.stat();
        size += before.size;
        if (before.size > DataBackupArchive.maxEntryBytes ||
            size > DataBackupArchive.maxExpandedBytes ||
            files.length + assets.length + agentSources.length + 3 >=
                DataBackupArchive.maxEntries) {
          throw const FormatException('外部源码超出完整备份大小或文件数量限制。');
        }
        final bytes = await readZip(entity), after = await entity.stat();
        if (before.size != after.size || before.modified != after.modified) {
          throw const FormatException('外部源码正在保存，请稍后再备份。');
        }
        agentSources[relative] = bytes;
      }
    }
    final nodes = await NodePluginBackup.collect(
      Directory(p.join(dataRoot.path, 'node_plugins')),
      maxBytes: DataBackupArchive.maxExpandedBytes - size,
      maxEntries:
          DataBackupArchive.maxEntries -
          files.length -
          assets.length -
          agentSources.length -
          3,
    );
    return BackupData(
      official,
      records,
      files,
      {
        'appVersion': AppConstants.appVersion,
        'appBuild': AppConstants.appBuild,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'platform': Platform.operatingSystem,
        'containsSecrets': true,
      },
      assets: assets,
      agentWorkspace: agentSources,
      nodeWorkspace: nodes,
    );
  }

  Future<Uint8List> _encodeSnapshot() async {
    await beforeSnapshot?.call();
    late BackupData snapshot;
    try {
      snapshot = await _snapshot();
    } finally {
      await afterSnapshot?.call();
    }
    _progress('生成完整ZIP并校验数据');
    return Isolate.run(() => DataBackupArchive.encode(snapshot));
  }

  Future<Uint8List> exportZip() async {
    if (busy || restartRequired) throw StateError('迁移任务正在进行，请先完成当前操作。');
    busy = true;
    notifyListeners();
    try {
      return await _encodeSnapshot();
    } finally {
      busy = false;
      stage = '';
      notifyListeners();
    }
  }

  Future<BackupData> inspectZip(Uint8List bytes) =>
      Isolate.run(() => DataBackupArchive.decode(bytes));

  Future<Uint8List> readZip(File file) async {
    if (await file.length() > DataBackupArchive.maxZipBytes) {
      throw const FormatException('备份ZIP超过128MB。');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (builder.length + chunk.length > DataBackupArchive.maxZipBytes) {
        throw const FormatException('备份ZIP超过128MB。');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _writeJson(File target, Map<String, dynamic> value) async {
    final temporary = File('${target.path}.${const Uuid().v4()}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(target.path);
  }

  File get _journal => File(p.join(migrationRoot.path, 'pending.json'));

  Future<void> stageRestore(Uint8List bytes) async {
    if (busy || restartRequired) throw StateError('已有迁移任务等待完成。');
    busy = true;
    notifyListeners();
    try {
      _progress('校验完整备份');
      await inspectZip(bytes);
      await _directory(migrationRoot);
      _progress('停止机器人与插件，等待本地写入完成');
      await beforeRestore?.call();
      final id = const Uuid().v4();
      final before = File(p.join(migrationRoot.path, 'before-$id.zip'));
      await before.writeAsBytes(await _encodeSnapshot(), flush: true);
      final incoming = File(p.join(migrationRoot.path, 'incoming-$id.zip'));
      await incoming.writeAsBytes(bytes, flush: true);
      recoveryPath = before.path;
      await _writeJson(_journal, {'schema': 1, 'phase': 'pending', 'id': id});
      restartRequired = true;
      _progress('备份已准备好，重启应用后恢复');
    } catch (_) {
      if (!restartRequired) await onStageFailure?.call();
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Invoked only during startup. A crash while applying rolls back on the next
  /// startup; a normal error rolls back immediately and retains both ZIP files.
  Future<String?> applyPendingRestore() async {
    if (!await _journal.exists()) return null;
    await _directory(migrationRoot);
    final journalType = await FileSystemEntity.type(
      _journal.path,
      followLinks: false,
    );
    if (journalType != FileSystemEntityType.file ||
        await _journal.length() > 4096) {
      throw const FormatException('数据迁移记录无效。');
    }
    final raw = jsonDecode(await _journal.readAsString());
    if (raw is! Map ||
        raw['schema'] != 1 ||
        !RegExp(r'^[a-f0-9-]{36}$').hasMatch('${raw['id']}')) {
      throw const FormatException('数据迁移记录格式无效。');
    }
    final id = raw['id'] as String, phase = raw['phase'];
    if (!{
      'pending',
      'applying',
      'rollback',
      'done',
      'failed',
    }.contains(phase)) {
      throw const FormatException('数据迁移阶段无效。');
    }
    if (phase == 'done' || phase == 'failed') return null;
    final before = File(p.join(migrationRoot.path, 'before-$id.zip'));
    Future<void> rollback() async {
      await _writeJson(_journal, {'schema': 1, 'phase': 'rollback', 'id': id});
      final recovery = await inspectZip(await readZip(before));
      await _applyData(recovery, id, rollback: true);
      await _writeJson(_journal, {'schema': 1, 'phase': 'failed', 'id': id});
    }

    if (phase == 'applying' || phase == 'rollback') {
      await rollback();
      return '上次数据恢复被中断，已从恢复前完整备份还原。';
    }
    final incoming = File(p.join(migrationRoot.path, 'incoming-$id.zip'));
    late BackupData restored;
    try {
      restored = await inspectZip(await readZip(incoming));
      // Validate recovery BEFORE modifying the current application.
      await inspectZip(await readZip(before));
    } catch (_) {
      await _writeJson(_journal, {'schema': 1, 'phase': 'failed', 'id': id});
      return '待恢复文件已损坏或无法读取，已取消恢复，当前数据未改变。';
    }
    await _writeJson(_journal, {'schema': 1, 'phase': 'applying', 'id': id});
    try {
      await _applyData(restored, id);
      await _writeJson(_journal, {'schema': 1, 'phase': 'done', 'id': id});
      return '完整数据恢复成功。恢复前备份保存在本机数据迁移目录。';
    } catch (_) {
      await rollback();
      return '恢复未能完成，已还原恢复前的全部数据，请检查磁盘空间与文件权限。';
    }
  }

  Future<List<File>> recoveryBackups() async {
    if (!await migrationRoot.exists()) return [];
    await _directory(migrationRoot);
    final files = <File>[];
    await for (final file in migrationRoot.list(followLinks: false)) {
      if (file is File &&
          RegExp(
            r'^before-[a-f0-9-]{36}\.zip$',
          ).hasMatch(p.basename(file.path))) {
        files.add(file);
      }
    }
    return files
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  }

  Future<void> _applyData(
    BackupData data,
    String id, {
    bool rollback = false,
  }) async {
    final workspaceRoot = await _workspaceDirectory();
    await _directory(workspaceRoot);
    final parent = workspaceRoot.parent,
        root = await parent.resolveSymbolicLinks();
    final suffix =
        '${rollback ? 'rollback' : 'restore'}-$id-${const Uuid().v4()}';
    final staging = Directory(p.join(parent.path, '.plugin-workspace-$suffix'));
    if (!p.isWithin(root, p.normalize(staging.absolute.path))) {
      throw const FormatException('恢复临时目录超出数据目录。');
    }
    await staging.create();
    for (final entry in data.workspace.entries) {
      if (!DataBackupArchive.safePath(entry.key)) {
        throw const FormatException('备份工作区路径无效。');
      }
      final file = File(p.joinAll([staging.path, ...entry.key.split('/')]));
      if (!p.isWithin(staging.absolute.path, p.normalize(file.absolute.path))) {
        throw const FormatException('备份文件超出工作区。');
      }
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.value, flush: true);
    }
    final mediaRoot = Directory(p.join(dataRoot.path, 'portable-media'));
    await _directory(mediaRoot);
    final media = Directory(p.join(mediaRoot.path, suffix));
    await media.create();
    for (final entry in data.assets.entries) {
      if (!DataBackupArchive.safePath(entry.key)) {
        throw const FormatException('本地素材路径无效。');
      }
      final file = File(p.joinAll([media.path, ...entry.key.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.value, flush: true);
    }
    final official = Map<String, dynamic>.from(data.official),
        tables = Map<String, dynamic>.from(official['boxes'] as Map),
        emojis = Map<String, String>.from(tables['emojis'] as Map);
    for (final key in emojis.keys.toList()) {
      final emoji = Map<String, dynamic>.from(jsonDecode(emojis[key]!) as Map);
      for (final field in ['localPath', 'url']) {
        final value = emoji[field];
        if (value is String && value.startsWith('qqm-backup-asset://')) {
          final name = value.substring(19);
          if (!data.assets.containsKey(name)) {
            throw const FormatException('自定义表情图片缺失。');
          }
          emoji[field] = p.joinAll([media.path, ...name.split('/')]);
        }
      }
      emojis[key] = jsonEncode(emoji);
    }
    tables['emojis'] = emojis;
    official['boxes'] = tables;
    await storage.replaceAllData(official);
    await agent.replaceAllData(data.agent);
    final previous = Directory(
      p.join(parent.path, '.plugin-workspace-before-$suffix'),
    );
    // Both names are fixed children of the checked workspace parent. No file
    // from a ZIP decides an absolute destination. Keep the old tree recoverable.
    await workspaceRoot.rename(previous.path);
    try {
      await staging.rename(workspaceRoot.path);
    } catch (_) {
      await previous.rename(workspaceRoot.path);
      rethrow;
    }
    await _replaceAgentSources(data.agentWorkspace, suffix);
    await _replaceAgentSources(
      data.nodeWorkspace,
      suffix,
      directoryName: 'node_plugins',
    );
  }

  Future<void> _replaceAgentSources(
    Map<String, Uint8List> files,
    String suffix, {
    String directoryName = 'agent_sources',
  }) async {
    if (!['agent_sources', 'node_plugins'].contains(directoryName)) {
      throw const FormatException('未知源码恢复区域。');
    }
    final directory = Directory(p.join(dataRoot.path, directoryName));
    await _directory(directory);
    final root = await dataRoot.resolveSymbolicLinks(),
        staging = Directory(
          p.join(
            dataRoot.path,
            '.${directoryName.replaceAll('_', '-')}-$suffix',
          ),
        ),
        previous = Directory(
          p.join(
            dataRoot.path,
            '.${directoryName.replaceAll('_', '-')}-before-$suffix',
          ),
        );
    if (!p.isWithin(root, p.normalize(staging.absolute.path)) ||
        !p.isWithin(root, p.normalize(previous.absolute.path))) {
      throw const FormatException('源码恢复目录越界。');
    }
    await staging.create();
    for (final entry in files.entries) {
      if (!DataBackupArchive.safePath(entry.key)) {
        throw const FormatException('外部源码路径无效。');
      }
      final file = File(p.joinAll([staging.path, ...entry.key.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.value, flush: true);
    }
    await directory.rename(previous.path);
    try {
      await staging.rename(directory.path);
    } catch (_) {
      await previous.rename(directory.path);
      rethrow;
    }
  }
}
