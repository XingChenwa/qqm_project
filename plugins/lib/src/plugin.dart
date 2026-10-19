import 'package:hive/hive.dart';
import 'commands.dart';
import 'runtime.dart';

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

  /// 完整清单随本机配置持久化；运行时配置与可分发清单分开保存。
  final Map<String, dynamic> manifest;

  PluginInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    this.author = '',
    required this.directory,
    this.isEnabled = false,
    Map<String, dynamic>? config,
    this.permissions = const [],
    this.manifest = const {},
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
    'manifest': manifest,
  };

  factory PluginInfo.fromMap(Map<String, dynamic> map) => PluginInfo(
    id: map['id'] as String,
    name: map['name'] as String? ?? '',
    version: map['version'] as String? ?? '1.0.0',
    description: map['description'] as String? ?? '',
    author: map['author'] as String? ?? '',
    directory: map['directory'] as String? ?? '',
    isEnabled: map['isEnabled'] as bool? ?? false,
    config: Map<String, dynamic>.from(map['config'] as Map? ?? {}),
    permissions: List<String>.from(map['permissions'] as List? ?? []),
    manifest: Map<String, dynamic>.from(map['manifest'] as Map? ?? {}),
  );
}

/// Abstract plugin interface that all plugins must implement.
abstract class BotPlugin {
  Duration get executionTimeout => const Duration(seconds: 10);
  final PluginInfo info;
  PluginHost? host;
  List<PluginCommand> get commands => const [];

  /// Full-group delivery is not permission to react to every ordinary sentence.
  bool acceptsUnmentioned(PluginMessage message) =>
      parseSlashCommand(message.content) != null;

  Future<PluginReply?> execute(PluginMessage message) async {
    if (message.eventType == 'interaction') return onInteraction(message);
    final result = await handleMessage(message);
    return result == null || result.trim().isEmpty ? null : PluginReply(result);
  }

  Future<PluginReply?> onInteraction(PluginMessage message) async => null;

  BotPlugin(this.info);

  /// 统一入口，保留完整消息上下文。旧 Dart 插件无需改动。
  Future<String?> handleMessage(PluginMessage message) {
    final command = parseSlashCommand(message.content);
    return command == null
        ? onMessage(message)
        : onCommand(command.command, command.args);
  }

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
  final String senderRole;
  final bool isFullGroupMessage;
  final String eventType;
  final String callbackData;
  final List<Map<String, dynamic>> attachments;

  PluginMessage({
    required this.messageId,
    required this.sessionId,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.messageType,
    required this.isGroup,
    required this.timestamp,
    this.senderRole = '',
    this.isFullGroupMessage = false,
    this.eventType = 'message',
    this.callbackData = '',
    this.attachments = const [],
  });

  Map<String, dynamic> toMap() => {
    'message_id': messageId,
    'session_id': sessionId,
    'sender_id': senderId,
    'sender_name': senderName,
    'content': content,
    'message_type': messageType,
    'is_group': isGroup,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'sender_role': senderRole,
    'is_full_group_message': isFullGroupMessage,
    'event_type': eventType,
    if (callbackData.isNotEmpty) 'callback_data': callbackData,
    if (attachments.isNotEmpty) 'attachments': attachments,
  };
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
