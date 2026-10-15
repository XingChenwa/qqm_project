import 'package:hive/hive.dart';
import 'received_message.dart';

class MessageModel {
  final String id;
  final String sessionId;
  final String senderId;
  final String senderName;
  final String senderAvatarUrl;
  final String senderLevel;
  final String senderTitle;
  final String senderRole;
  final String content;
  final int messageType; // 0=text, 2=markdown, 7=image
  final DateTime timestamp;
  final bool isFromBot;
  bool isRead;
  final bool isRecalled;
  final String? imageUrl;
  final String? markdownContent;
  final Map<String, dynamic>? extra;

  Map<String, dynamic> get rawEvent => extra?['extra'] is Map
      ? Map<String, dynamic>.from(extra!['extra'])
      : (extra ?? const {});
  ReceivedMessageBody get receivedBody => ReceivedMessageBody.fromMap(rawEvent);
  bool get hasReceivedPayload =>
      !isFromBot &&
      (rawEvent.containsKey('message_type') ||
          rawEvent.containsKey('attachments') ||
          rawEvent.containsKey('ark_data') ||
          rawEvent.containsKey('msg_elements'));
  bool get isFullGroupMessage => extra?['eventType'] == 'GROUP_MESSAGE_CREATE';
  bool get isBotAuthor =>
      isFromBot ||
      extra?['senderIsBot'] == true ||
      (rawEvent['author'] is Map && rawEvent['author']['bot'] == true);
  int get sourceMessageType =>
      int.tryParse(
        (extra?['sourceMessageType'] ?? rawEvent['message_type'] ?? 0)
            .toString(),
      ) ??
      0;
  String get sessionPreview => hasReceivedPayload
      ? receivedBody.preview
      : (markdownContent?.isNotEmpty == true
            ? '[Markdown] $markdownContent'
            : (content.trim().isNotEmpty
                  ? content
                  : (imageUrl?.isNotEmpty == true ? '[图片]' : '[消息]')));

  String get referenceIndex {
    for (final node in [extra, extra?['extra'], extra?['response']]) {
      if (node is! Map) continue;
      final direct = node['referenceIndex']?.toString() ?? '';
      if (direct.isNotEmpty) return direct;
      final extInfo = node['ext_info'];
      if (extInfo is Map && (extInfo['ref_idx']?.toString() ?? '').isNotEmpty) {
        return extInfo['ref_idx'].toString();
      }
      final scene = node['message_scene'];
      final entries = scene is Map ? scene['ext'] : null;
      if (entries is List) {
        for (final entry in entries) {
          if (entry is String && entry.startsWith('msg_idx=')) {
            return entry.substring(8);
          }
        }
      }
    }
    return '';
  }

  MessageModel({
    required this.id,
    required this.sessionId,
    required this.senderId,
    required this.senderName,
    this.senderAvatarUrl = '',
    this.senderLevel = '',
    this.senderTitle = '',
    this.senderRole = '',
    required this.content,
    required this.messageType,
    required this.timestamp,
    this.isFromBot = false,
    this.isRead = false,
    this.isRecalled = false,
    this.imageUrl,
    this.markdownContent,
    this.extra,
  });

  MessageModel copyWith({
    bool? isRead,
    String? content,
    bool? isRecalled,
    String? senderName,
    String? senderAvatarUrl,
    String? senderRole,
  }) {
    return MessageModel(
      id: id,
      sessionId: sessionId,
      senderId: senderId,
      senderName: senderName ?? this.senderName,
      senderAvatarUrl: senderAvatarUrl ?? this.senderAvatarUrl,
      senderLevel: senderLevel,
      senderTitle: senderTitle,
      senderRole: senderRole ?? this.senderRole,
      content: content ?? this.content,
      messageType: messageType,
      timestamp: timestamp,
      isFromBot: isFromBot,
      isRead: isRead ?? this.isRead,
      isRecalled: isRecalled ?? this.isRecalled,
      imageUrl: imageUrl,
      markdownContent: markdownContent,
      extra: extra,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'sessionId': sessionId,
    'senderId': senderId,
    'senderName': senderName,
    'senderAvatarUrl': senderAvatarUrl,
    'senderLevel': senderLevel,
    'senderTitle': senderTitle,
    'senderRole': senderRole,
    'content': content,
    'messageType': messageType,
    'timestamp': timestamp.toIso8601String(),
    'isFromBot': isFromBot,
    'isRead': isRead,
    'isRecalled': isRecalled,
    'imageUrl': imageUrl,
    'markdownContent': markdownContent,
    'extra': _jsonSafe(extra),
  };

  factory MessageModel.fromMap(Map<String, dynamic> map) => MessageModel(
    id: map['id'] as String,
    sessionId: map['sessionId'] as String,
    senderId: map['senderId'] as String? ?? '',
    senderName: map['senderName'] as String? ?? '',
    senderAvatarUrl: map['senderAvatarUrl'] as String? ?? '',
    senderLevel: map['senderLevel'] as String? ?? '',
    senderTitle: map['senderTitle'] as String? ?? '',
    senderRole: map['senderRole'] as String? ?? '',
    content: map['content'] as String? ?? '',
    messageType: map['messageType'] as int? ?? 0,
    timestamp: DateTime.parse(map['timestamp'] as String).toLocal(),
    isFromBot: map['isFromBot'] as bool? ?? false,
    isRead: map['isRead'] as bool? ?? false,
    isRecalled: map['isRecalled'] as bool? ?? false,
    imageUrl: map['imageUrl'] as String?,
    markdownContent: map['markdownContent'] as String?,
    extra: map['extra'] as Map<String, dynamic>?,
  );
}

dynamic _jsonSafe(dynamic value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is DateTime) return value.toIso8601String();
  if (value is List) return value.map(_jsonSafe).toList();
  if (value is Map) {
    return value.map(
      (key, mapValue) => MapEntry(key.toString(), _jsonSafe(mapValue)),
    );
  }
  return value.toString();
}

class ChatSession {
  final String id;
  final String name;
  final String avatarUrl;
  final int sessionType; // 0=friends, 1=group
  final DateTime lastMessageTime;
  final String lastMessage;
  int unreadCount;
  final bool isPinned;
  final String profileStatus;
  final DateTime? profileUpdatedAt;
  final String nicknameSource;
  final String nicknameAppId;
  final DateTime? nicknameUpdatedAt;

  ChatSession({
    required this.id,
    required this.name,
    this.avatarUrl = '',
    required this.sessionType,
    required this.lastMessageTime,
    this.lastMessage = '',
    this.unreadCount = 0,
    this.isPinned = false,
    this.profileStatus = '',
    this.profileUpdatedAt,
    this.nicknameSource = '',
    this.nicknameAppId = '',
    this.nicknameUpdatedAt,
  });

  ChatSession copyWith({
    String? name,
    String? avatarUrl,
    String? lastMessage,
    DateTime? lastMessageTime,
    int? unreadCount,
    String? profileStatus,
    DateTime? profileUpdatedAt,
    String? nicknameSource,
    String? nicknameAppId,
    DateTime? nicknameUpdatedAt,
  }) => ChatSession(
    id: id,
    name: name ?? this.name,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    sessionType: sessionType,
    lastMessageTime: lastMessageTime ?? this.lastMessageTime,
    lastMessage: lastMessage ?? this.lastMessage,
    unreadCount: unreadCount ?? this.unreadCount,
    isPinned: isPinned,
    profileStatus: profileStatus ?? this.profileStatus,
    profileUpdatedAt: profileUpdatedAt ?? this.profileUpdatedAt,
    nicknameSource: nicknameSource ?? this.nicknameSource,
    nicknameAppId: nicknameAppId ?? this.nicknameAppId,
    nicknameUpdatedAt: nicknameUpdatedAt ?? this.nicknameUpdatedAt,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'avatarUrl': avatarUrl,
    'sessionType': sessionType,
    'lastMessageTime': lastMessageTime.toIso8601String(),
    'lastMessage': lastMessage,
    'unreadCount': unreadCount,
    'isPinned': isPinned,
    'profileStatus': profileStatus,
    'profileUpdatedAt': profileUpdatedAt?.toIso8601String(),
    'nicknameSource': nicknameSource,
    'nicknameAppId': nicknameAppId,
    'nicknameUpdatedAt': nicknameUpdatedAt?.toIso8601String(),
  };

  factory ChatSession.fromMap(Map<String, dynamic> map) => ChatSession(
    id: map['id'] as String,
    name: map['name'] as String? ?? '',
    avatarUrl: map['avatarUrl'] as String? ?? '',
    sessionType: map['sessionType'] as int? ?? 0,
    lastMessageTime: DateTime.parse(
      map['lastMessageTime'] as String? ?? DateTime.now().toIso8601String(),
    ).toLocal(),
    lastMessage: map['lastMessage'] as String? ?? '',
    unreadCount: map['unreadCount'] as int? ?? 0,
    isPinned: map['isPinned'] as bool? ?? false,
    profileStatus: map['profileStatus'] as String? ?? '',
    profileUpdatedAt: DateTime.tryParse(
      map['profileUpdatedAt']?.toString() ?? '',
    ),
    nicknameSource: map['nicknameSource'] as String? ?? '',
    nicknameAppId: map['nicknameAppId'] as String? ?? '',
    nicknameUpdatedAt: DateTime.tryParse(
      map['nicknameUpdatedAt']?.toString() ?? '',
    ),
  );
}

class EmojiItem {
  final String id;
  final String name;
  final String url;
  final String category;
  final bool isCustom;
  final String? localPath;

  EmojiItem({
    required this.id,
    required this.name,
    required this.url,
    this.category = '默认',
    this.isCustom = false,
    this.localPath,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'url': url,
    'category': category,
    'isCustom': isCustom,
    'localPath': localPath,
  };

  factory EmojiItem.fromMap(Map<String, dynamic> map) => EmojiItem(
    id: map['id'] as String,
    name: map['name'] as String? ?? '',
    url: map['url'] as String? ?? '',
    category: map['category'] as String? ?? '默认',
    isCustom: map['isCustom'] as bool? ?? false,
    localPath: map['localPath'] as String?,
  );
}

// Hive TypeAdapters
class MessageModelAdapter extends TypeAdapter<MessageModel> {
  @override
  final int typeId = 0;

  @override
  MessageModel read(BinaryReader reader) {
    final map = Map<String, dynamic>.from(
      (reader.readMap()).map((k, v) => MapEntry(k.toString(), v)),
    );
    return MessageModel.fromMap(map);
  }

  @override
  void write(BinaryWriter writer, MessageModel obj) {
    writer.writeMap(obj.toMap());
  }
}

class ChatSessionAdapter extends TypeAdapter<ChatSession> {
  @override
  final int typeId = 1;

  @override
  ChatSession read(BinaryReader reader) {
    final map = Map<String, dynamic>.from(
      (reader.readMap()).map((k, v) => MapEntry(k.toString(), v)),
    );
    return ChatSession.fromMap(map);
  }

  @override
  void write(BinaryWriter writer, ChatSession obj) {
    writer.writeMap(obj.toMap());
  }
}

class EmojiItemAdapter extends TypeAdapter<EmojiItem> {
  @override
  final int typeId = 2;

  @override
  EmojiItem read(BinaryReader reader) {
    final map = Map<String, dynamic>.from(
      (reader.readMap()).map((k, v) => MapEntry(k.toString(), v)),
    );
    return EmojiItem.fromMap(map);
  }

  @override
  void write(BinaryWriter writer, EmojiItem obj) {
    writer.writeMap(obj.toMap());
  }
}
