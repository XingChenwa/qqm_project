import '../agent/controller.dart';
import '../services/official_reply_sequences.dart';
import '../services/storage_service.dart';
import 'bot_client.dart';

/// Share only QQ protocol sequencing; workspaces retain their own databases,
/// credentials, chats, triggers and plugin runtimes.
void linkOfficialWorkspaces(
  BotClient bot,
  AgentController agent,
  StorageService storage,
) {
  final sequences = OfficialReplySequences(
    read: storage.officialReplySequence,
    write: storage.saveOfficialReplySequence,
  );
  bot.officialReplySequences = sequences;
  agent.officialReplySequences = sequences;
}
