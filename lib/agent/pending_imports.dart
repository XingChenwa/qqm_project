import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'extensions.dart';
import 'models.dart';

String? defaultAgentPendingImportsDirectory() {
  if (!Platform.isWindows) return null;
  final local = Platform.environment['LOCALAPPDATA'];
  return local == null || local.isEmpty
      ? null
      : path.join(local, 'QQBotManager', 'agent-imports');
}

/// The installer queues one declarative local service Skill. Never run arbitrary
/// ZIP/JS startup code. Managed updates preserve user settings and bindings.
Future<AgentExtension?> readPendingCoverSkill(String directory) async {
  final file = File(path.join(directory, 'local-rvc-cover.json'));
  if (!await file.exists() ||
      await FileSystemEntity.isLink(file.path) ||
      await file.length() > 65536) {
    return null;
  }
  final extension = AgentExtension.parse(
    await file.readAsString(),
    filename: file.path,
  );
  if (extension.id != 'local_rvc_cover' ||
      extension.kind != 'skill' ||
      extension.isJavaScript ||
      extension.origins.length != 1 ||
      extension.origins.single != 'http://127.0.0.1:23339' ||
      extension.tools.any((tool) {
        final handler = object(tool['handler']);
        return handler['type'] != 'http' ||
            handler['url'] != 'http://127.0.0.1:23339/api/tool' ||
            handler['method'] != 'POST';
      })) {
    throw const AgentException('待安装的本地翻唱 Skill 不符合固定服务配置。');
  }
  return extension.copyWith(enabled: false);
}

String coverSkillDigest(AgentExtension extension) {
  Object? canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  return sha256
      .convert(utf8.encode(jsonEncode(canonical(extension.manifest))))
      .toString();
}

/// Only replace the exact previously shipped manifest (or our last installed
/// revision). Editing a user's custom prompt/tools would break their workflow.
bool canUpgradeCoverSkill(AgentExtension existing, String? installedDigest) {
  final digest = coverSkillDigest(existing);
  return digest == installedDigest ||
      digest ==
          '73aa5d697061e94d6b58ae065eed90cae7f0919425bcbdf3adf56639452b0a39';
}
