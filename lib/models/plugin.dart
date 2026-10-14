import 'package:hive/hive.dart';

class PluginInfo {
  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final String directory;
  bool isEnabled;
  final Map<String, dynamic> config;
  final List<String> permissions;

  PluginInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    this.author = '',
    required this.directory,
    this.isEnabled = true,
    Map<String, dynamic>? config,
    this.permissions = const [],
  }) : config = config ?? {};

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'version': version,
    'description': description,
    'author': author,
    'directory': directory,
    'isEnabled': isEnabled,
    'config': config,
    'permissions': permissions,
  };

  factory PluginInfo.fromMap(Map<String, dynamic> map) => PluginInfo(
    id: map['id'] as String,
    name: map['name'] as String? ?? '',
    version: map['version'] as String? ?? '1.0.0',
    description: map['description'] as String? ?? '',
    author: map['author'] as String? ?? '',
    directory: map['directory'] as String? ?? '',
    isEnabled: map['isEnabled'] as bool? ?? true,
    config: Map<String, dynamic>.from(map['config'] as Map? ?? {}),
    permissions: List<String>.from(map['permissions'] as List? ?? []),
  );
}

/// Abstract plugin interface that all plugins must implement.
abstract class BotPlugin {
  Duration get executionTimeout => const Duration(seconds: 10);
  final PluginInfo info;

  BotPlugin(this.info);

  /// Called when the plugin is loaded and enabled.
  Future<void> onEnable();

  /// Called when the plugin is disabled.
  Future<void> onDisable();

  /// Called when a message is received. Return a reply string or null.
  Future<String?> onMessage(PluginMessage message);

  /// Called when a slash command is invoked (e.g., /weather Beijing).
  Future<String?> onCommand(String command, List<String> args);

  /// Called periodically for background tasks (optional).
  Future<void> onTick() async {}

  /// Update plugin configuration at runtime.
  Future<void> updateConfig(Map<String, dynamic> newConfig) async {
    info.config.addAll(newConfig);
  }
}

/// Simplified message passed to plugins.
class PluginMessage {
  final String messageId;
  final String sessionId;
  final String senderId;
  final String senderName;
  final String content;
  final int messageType;
  final bool isGroup;
  final DateTime timestamp;

  PluginMessage({
    required this.messageId,
    required this.sessionId,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.messageType,
    required this.isGroup,
    required this.timestamp,
  });
}

class PluginConfigAdapter extends TypeAdapter<PluginInfo> {
  @override
  final int typeId = 3;

  @override
  PluginInfo read(BinaryReader reader) {
    final map = Map<String, dynamic>.from(
      (reader.readMap()).map((k, v) => MapEntry(k.toString(), v)),
    );
    return PluginInfo.fromMap(map);
  }

  @override
  void write(BinaryWriter writer, PluginInfo obj) {
    writer.writeMap(obj.toMap());
  }
}
