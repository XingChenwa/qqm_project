import 'package:logging/logging.dart';
import '../models/message.dart';
import '../models/config.dart';
import '../services/storage_service.dart';

class MessageHandler {
  final Logger _log = Logger('MessageHandler');
  final StorageService _storage;
  BotConfig _config;

  // Auto-reply rules
  final Map<String, String> _keywordReplies = {};

  MessageHandler(this._storage) : _config = _storage.getBotConfig() {
    _loadConfig();
  }

  void _loadConfig() {
    _config = _storage.getBotConfig();
    _keywordReplies.clear();
    _keywordReplies.addAll(_config.keywordReplies);
  }

  void refreshConfig() {
    _loadConfig();
  }

  /// Process an incoming message and determine if auto-reply is needed.
  /// Returns a reply string or null.
  String? processMessage(MessageModel message) {
    if (message.isBotAuthor || message.isRecalled) return null;
    if (message.isFullGroupMessage && !_config.autoReplyToAllGroupMessages) {
      return null;
    }
    if (!_config.enableAutoReply) return null;

    final content = message.content.trim();

    // Check for exact keyword matches
    for (final entry in _keywordReplies.entries) {
      if (content == entry.key) {
        _log.info('Keyword match: "${entry.key}" -> "${entry.value}"');
        return entry.value;
      }
    }

    // Default auto-reply if no keyword matched
    if (_config.defaultAutoReply.isNotEmpty) {
      return _config.defaultAutoReply;
    }

    return null;
  }

  /// Add a keyword reply rule.
  void addKeywordReply(String keyword, String reply) {
    _keywordReplies[keyword] = reply;
    _saveKeywordReplies();
  }

  /// Remove a keyword reply rule.
  void removeKeywordReply(String keyword) {
    _keywordReplies.remove(keyword);
    _saveKeywordReplies();
  }

  void _saveKeywordReplies() {
    _config.keywordReplies = Map.from(_keywordReplies);
    _storage.saveBotConfig(_config);
  }

  Map<String, String> get keywordReplies => Map.unmodifiable(_keywordReplies);
}
