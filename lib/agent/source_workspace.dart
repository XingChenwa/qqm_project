import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import 'extension_files.dart';
import 'models.dart';

/// Real source files for external editors. File saving is independent of code
/// validation; invalid drafts stay on disk while the last valid package runs.
class AgentSourceWorkspace {
  final Directory root;
  final AgentExtensionFiles Function(String) lookup;
  final Future<void> Function(String, Map<String, Uint8List>, String) apply;
  final void Function(String, String, bool) onStatus;
  final String Function(Object) describeError;
  final _watchers = <String, StreamSubscription<FileSystemEvent>>{};
  final _timers = <String, Timer>{};
  final _tracked = <String>{}, _applying = <String>{};
  Future<void> _work = Future.value();
  bool _paused = false, _closed = false;
  AgentSourceWorkspace({
    required this.root,
    required this.lookup,
    required this.apply,
    required this.onStatus,
    required this.describeError,
  });
  bool contains(String id) => _tracked.contains(id);
  bool applying(String id) => _applying.contains(id);
  Future<T> _serial<T>(Future<T> Function() action) {
    final task = _work.then((_) => action());
    _work = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  Future<void> _directory(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const AgentException('源码目录不能是链接或普通文件。');
    }
    await directory.create(recursive: true);
  }

  Directory _project(String id) {
    if (!safeId(id)) throw const AgentException('扩展ID无效。');
    final directory = Directory(p.join(root.path, _folderName(id)));
    if (!p.isWithin(
      p.normalize(root.absolute.path),
      p.normalize(directory.absolute.path),
    )) {
      throw const AgentException('源码目录超出工作区。');
    }
    return directory;
  }

  String _folderName(String id) =>
      '$id-${sha256.convert(utf8.encode(id)).toString().substring(0, 8)}';

  Future<File> _file(Directory directory, String name) async {
    AgentExtensionFiles.validatePath(name);
    var parent = directory;
    final parts = name.split('/');
    for (final part in parts.take(parts.length - 1)) {
      parent = Directory(p.join(parent.path, part));
      await _directory(parent);
    }
    final file = File(p.join(parent.path, parts.last));
    if (!p.isWithin(
      p.normalize(directory.absolute.path),
      p.normalize(file.absolute.path),
    )) {
      throw const AgentException('文件超出源码目录。');
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const AgentException('源码文件不能是链接或目录。');
    }
    return file;
  }

  Future<void> _atomic(File file, List<int> bytes) async {
    final temporary = File(
      p.join(file.parent.path, '.qqm-tmp-${const Uuid().v4()}'),
    );
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }

  Future<File> _stateFile(String id) async {
    final state = Directory(p.join(root.path, '.state'));
    await _directory(state);
    return _file(state, '${_folderName(id)}.json');
  }

  Future<Json> _state(String id) async {
    final file = await _stateFile(id);
    if (!await file.exists()) return {};
    if (await file.length() > 1024 * 1024) {
      throw const AgentException('源码同步记录过大。');
    }
    try {
      return object(jsonDecode(await file.readAsString()));
    } catch (_) {
      throw const AgentException('源码同步记录损坏；现有源文件已保留。');
    }
  }

  Future<void> _remember(
    String id,
    String revision, {
    String? diskRevision,
  }) async => _atomic(
    await _stateFile(id),
    utf8.encode(
      jsonEncode({
        'schema': 1,
        'revision': revision,
        'diskRevision': diskRevision ?? revision,
      }),
    ),
  );
  Future<Map<String, Uint8List>> _read(String id) async {
    final directory = _project(id), files = <String, Uint8List>{};
    await _directory(directory);
    var total = 0;
    Future<void> walk(Directory current) async {
      await for (final item in current.list(followLinks: false)) {
        final relative = p
            .relative(item.path, from: directory.path)
            .replaceAll('\\', '/');
        final leaf = p.basename(item.path);
        if (leaf.startsWith('.qqm-tmp-') ||
            {'.git', 'node_modules', '.DS_Store', 'Thumbs.db'}.contains(leaf)) {
          continue;
        }
        final type = await FileSystemEntity.type(item.path, followLinks: false);
        if (type == FileSystemEntityType.link) {
          throw const AgentException('源码目录含链接，未加载外部修改；原文件保持不变。');
        }
        if (item is Directory) {
          await walk(item);
          continue;
        }
        if (item is! File) continue;
        AgentExtensionFiles.validatePath(relative);
        final before = await item.stat();
        if (before.size > 8 * 1024 * 1024 ||
            (total += before.size) > 24 * 1024 * 1024 ||
            files.length >= 300) {
          throw const AgentException('文件已保存在磁盘；当前运行包支持300个文件、单文件8MB、总计24MB。');
        }
        final output = BytesBuilder(copy: false);
        await for (final chunk in item.openRead()) {
          if (output.length + chunk.length > 8 * 1024 * 1024) {
            throw const AgentException('文件仍在写入，请稍后重新加载。');
          }
          output.add(chunk);
        }
        final after = await item.stat();
        if (before.size != after.size || before.modified != after.modified) {
          throw const AgentException('文件仍在写入，请稍后重新加载。');
        }
        files[relative] = output.takeBytes();
      }
    }

    await walk(directory);
    return files;
  }

  Future<void> _write(
    String id,
    Map<String, Uint8List> files, {
    Map<String, Uint8List> previous = const {},
  }) async {
    final directory = _project(id);
    await _directory(directory);
    for (final entry in files.entries) {
      await _atomic(await _file(directory, entry.key), entry.value);
    }
    for (final name in previous.keys.where(
      (name) => !files.containsKey(name),
    )) {
      final file = await _file(directory, name);
      // _file validates the absolute destination is inside this project.
      if (await file.exists()) await file.delete();
    }
  }

  Future<Directory> prepare(String id) => _serial(() async {
    if (_closed || _paused) throw const AgentException('源码同步已暂停。');
    await _directory(root);
    final directory = _project(id), source = lookup(id);
    final existed = await directory.exists();
    await _directory(directory);
    if (!existed) {
      await _write(id, source.files);
      await _remember(id, source.revision);
    }
    _tracked.add(id);
    try {
      await _sync(id);
    } catch (error) {
      _report(id, error);
    }
    _watch(id);
    return directory;
  });
  Future<void> resumeExisting(Iterable<String> ids) async {
    if (!await root.exists()) return;
    for (final id in ids) {
      try {
        if (await _project(id).exists()) {
          await prepare(id);
        }
      } catch (error) {
        _report(id, error);
      }
    }
  }

  Future<void> _sync(String id, {bool force = false}) async {
    final source = lookup(id),
        files = await _read(id),
        revision = AgentExtensionFiles.revisionOf(files),
        state = force ? <String, dynamic>{} : await _state(id),
        base = text(state['revision']),
        baseDisk = text(state['diskRevision']).isEmpty
            ? text(state['revision'])
            : text(state['diskRevision']);
    if (revision == source.revision ||
        (revision == baseDisk && source.revision == base)) {
      await _remember(id, source.revision, diskRevision: revision);
      onStatus(id, '源文件已同步', false);
      return;
    }
    if (!force && base.isNotEmpty && base != source.revision) {
      if (revision == baseDisk) {
        await _write(id, source.files, previous: files);
        await _remember(id, source.revision);
        onStatus(id, '应用内修改已同步到源码目录', false);
        return;
      }
      throw const AgentException('磁盘源码和应用内源码均有修改，文件均已保留。点击“重新加载源码”可明确采用磁盘版本。');
    }
    // Wait for editors that save using a temporary file/rename or two writes.
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final stable = await _read(id);
    if (AgentExtensionFiles.revisionOf(stable) != revision) {
      throw const AgentException('文件仍在写入，等待下次保存后再加载。');
    }
    _applying.add(id);
    try {
      await apply(id, files, source.revision);
    } finally {
      _applying.remove(id);
    }
    await _remember(id, lookup(id).revision, diskRevision: revision);
    onStatus(id, '外部源码已重新加载', false);
  }

  String _report(String id, Object error) {
    final detail = error is FormatException
        ? 'JSON / YAML 格式错误${error.offset == null ? '' : '（字符位置 ${error.offset}）'}，请修正后重新加载。'
        : error is FileSystemException
        ? '本地文件读写未完成${error.osError == null ? '' : '（系统错误码 ${error.osError!.errorCode}）'}，请检查文件权限。'
        : describeError(error);
    final message = '源文件已保留，加载未完成：$detail';
    onStatus(id, message, true);
    return message;
  }

  void _watch(String id) {
    if (_watchers.containsKey(id) || _closed) return;
    try {
      _watchers[id] = _project(id)
          .watch(recursive: true)
          .listen(
            (event) {
              if (_closed ||
                  _paused ||
                  p.basename(event.path).startsWith('.qqm-tmp-')) {
                return;
              }
              _timers.remove(id)?.cancel();
              _timers[id] = Timer(const Duration(milliseconds: 800), () {
                _timers.remove(id);
                unawaited(synchronize(id));
              });
            },
            onError: (Object _) {
              onStatus(id, '目录不支持自动监听，请保存后点击“重新加载源码”。', true);
            },
          );
    } catch (_) {
      onStatus(id, '目录不支持自动监听，请保存后点击“重新加载源码”。', true);
    }
  }

  Future<void> synchronize(
    String id, {
    bool force = false,
    bool throwErrors = false,
  }) => _serial(() async {
    if (_closed || _paused || !_tracked.contains(id)) return;
    try {
      await _sync(id, force: force);
    } catch (error) {
      final message = _report(id, error);
      if (throwErrors) throw AgentException(message);
    }
  });
  Future<void> pause() async {
    _paused = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    await _work;
  }

  void resume() {
    if (_closed) return;
    _paused = false;
    for (final id in _tracked) {
      unawaited(synchronize(id));
    }
  }

  Future<void> forget(String id) async {
    _tracked.remove(id);
    _timers.remove(id)?.cancel();
    await _watchers.remove(id)?.cancel();
  }

  Future<void> close() async {
    _closed = true;
    await pause();
    for (final watcher in _watchers.values) {
      await watcher.cancel();
    }
    _watchers.clear();
  }
}
