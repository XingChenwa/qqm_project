import '../models/message.dart';
import '../models/received_message.dart';

enum HistoryFilter { all, images, voice, files }

Iterable<ReceivedAttachment> historyAttachments(
  ReceivedMessageBody body,
) sync* {
  yield* body.attachments;
  for (final element in body.elements) {
    yield* historyAttachments(element);
  }
}

String historyMessageText(MessageModel message) {
  if (message.isRecalled) return '这条消息已撤回';
  final parts = <String>[message.senderName, message.senderId];
  void visit(ReceivedMessageBody body) {
    parts.addAll([body.authorName, body.displayText]);
    if (body.card case final card?) {
      parts.addAll([card.name, card.title, card.description, card.source]);
    }
    for (final attachment in body.attachments) {
      parts.addAll([attachment.displayName, attachment.transcript]);
    }
    for (final element in body.elements) {
      visit(element);
    }
  }

  if (message.hasReceivedPayload) {
    visit(message.receivedBody);
  } else {
    parts.add(message.markdownContent ?? message.content);
  }
  return parts.where((part) => part.isNotEmpty).join('\n');
}

bool matchesHistoryFilter(MessageModel message, HistoryFilter filter) {
  if (filter == HistoryFilter.all) return true;
  if (message.isRecalled) return false;
  final mediaType = message.extra?['mediaFileType'];
  final attachments = historyAttachments(message.receivedBody);
  return switch (filter) {
    HistoryFilter.images =>
      (message.imageUrl?.isNotEmpty == true &&
              (mediaType == null || mediaType == 1)) ||
          attachments.any((a) => a.isImage),
    HistoryFilter.voice => mediaType == 3 || attachments.any((a) => a.isVoice),
    HistoryFilter.files =>
      mediaType == 4 ||
          attachments.any((a) => !a.isImage && !a.isVoice && !a.isVideo),
    HistoryFilter.all => true,
  };
}

/// Keep a matching fragment visible even when it occurs deep inside a quote.
String historyMatchSnippet(MessageModel message, String query) {
  final text = historyMessageText(
    message,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  final term = query.trim().toLowerCase();
  final match = text.toLowerCase().indexOf(term);
  final start = match > 22 ? match - 22 : 0;
  final end = (start + 90).clamp(0, text.length);
  return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
}
