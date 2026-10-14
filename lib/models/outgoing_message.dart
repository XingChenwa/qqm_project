enum ReplyMode { automatic, active, message, event }

class MessageComposerSettings {
  final bool explicitType;
  final int type;
  final int mediaFileType;
  final String mediaSource;
  final String fileInfo;
  final MessageSendOptions options;
  const MessageComposerSettings({
    this.explicitType = false,
    this.type = 0,
    this.mediaFileType = 1,
    this.mediaSource = '',
    this.fileInfo = '',
    this.options = const MessageSendOptions(),
  });

  bool get isConfigured => explicitType || type == 7 || options.isConfigured;
  MessageComposerSettings withType(int value) => MessageComposerSettings(
    explicitType: explicitType,
    type: value,
    mediaFileType: mediaFileType,
    mediaSource: mediaSource,
    fileInfo: fileInfo,
    options: options,
  );
  MessageComposerSettings withOptions(MessageSendOptions value) =>
      MessageComposerSettings(
        explicitType: explicitType,
        type: type,
        mediaFileType: mediaFileType,
        mediaSource: mediaSource,
        fileInfo: fileInfo,
        options: value,
      );
}

class MessageSendOptions {
  final ReplyMode replyMode;
  final String messageId;
  final String eventId;
  final int? sequence;
  final String referenceId;
  final bool quoteSelectedMessage;
  final bool forceVerifyImage;
  final MessageKeyboard? keyboard;

  const MessageSendOptions({
    this.replyMode = ReplyMode.automatic,
    this.messageId = '',
    this.eventId = '',
    this.sequence,
    this.referenceId = '',
    this.quoteSelectedMessage = true,
    this.forceVerifyImage = false,
    this.keyboard,
  });

  MessageSendOptions withQuote(bool value) => MessageSendOptions(
    replyMode: replyMode,
    messageId: messageId,
    eventId: eventId,
    sequence: sequence,
    referenceId: referenceId,
    quoteSelectedMessage: value,
    forceVerifyImage: forceVerifyImage,
    keyboard: keyboard,
  );

  bool get isConfigured =>
      replyMode != ReplyMode.automatic ||
      sequence != null ||
      referenceId.isNotEmpty ||
      forceVerifyImage ||
      keyboard != null;

  String? validate({required bool isGroup}) {
    if (messageId.isNotEmpty && eventId.isNotEmpty) {
      return '消息 ID 和事件 ID 只能选择一种';
    }
    if (replyMode == ReplyMode.message && messageId.trim().isEmpty) {
      return '请填写被动回复的消息 ID';
    }
    if (replyMode == ReplyMode.event && eventId.trim().isEmpty) {
      return '请填写可回复的事件 ID';
    }
    if (sequence != null && sequence! < 1) return '回复序号必须是大于 0 的整数';
    if (replyMode == ReplyMode.active && sequence != null) return '主动消息不使用回复序号';
    return keyboard?.validate(isGroup: isGroup);
  }
}

class MessageKeyboard {
  final String templateId;
  final List<List<MessageButton>> rows;
  const MessageKeyboard({this.templateId = '', this.rows = const []});

  String? validate({required bool isGroup}) {
    if (templateId.isNotEmpty) {
      return rows.isNotEmpty ? '按钮模板和自定义按钮不能同时使用' : null;
    }
    if (rows.isEmpty || rows.length > 5) return '自定义键盘需要 1～5 行按钮';
    final ids = <String>{};
    for (final row in rows) {
      if (row.isEmpty || row.length > 5) return '每行需要 1～5 个按钮';
      for (final button in row) {
        if (!ids.add(button.id.trim())) return '同一键盘的按钮 ID 不能重复';
        final error = button.validate(isGroup: isGroup);
        if (error != null) return error;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => templateId.isNotEmpty
      ? {'id': templateId.trim()}
      : {
          'content': {
            'rows': [
              for (final row in rows)
                {
                  'buttons': [for (final button in row) button.toJson()],
                },
            ],
          },
        };
}

class MessageButton {
  final String id;
  final String label;
  final String visitedLabel;
  final int style;
  final int actionType;
  final String data;
  final int permissionType;
  final List<String> userIds;
  final String groupId;
  final String unsupportedTips;
  final bool enter;
  final bool reply;
  final bool openImagePicker;
  final String confirmContent;
  final String confirmText;
  final String cancelText;

  const MessageButton({
    required this.id,
    required this.label,
    this.visitedLabel = '',
    this.style = 1,
    this.actionType = 2,
    this.data = '',
    this.permissionType = 2,
    this.userIds = const [],
    this.groupId = '',
    this.unsupportedTips = '请更新 QQ 后重试',
    this.enter = false,
    this.reply = false,
    this.openImagePicker = false,
    this.confirmContent = '',
    this.confirmText = '',
    this.cancelText = '',
  });

  String? validate({required bool isGroup}) {
    if (id.trim().isEmpty) return '按钮 ID 不能为空';
    if (label.trim().isEmpty || label.runes.length > 10) {
      return '按钮文字需为 1～10 个字符';
    }
    if (visitedLabel.runes.length > 10) return '点击后文字最多 10 个字符';
    if (![0, 1, 3, 4].contains(style)) return '请选择有效的按钮样式';
    if (![0, 1, 2].contains(actionType)) return '请选择有效的按钮动作';
    if (data.trim().isEmpty) return '请填写按钮跳转地址、回调数据或指令';
    if (![0, 1, 2].contains(permissionType)) return '请选择有效的按钮权限';
    if (permissionType == 0 &&
        (userIds.isEmpty || userIds.any((id) => id.trim().isEmpty))) {
      return '指定用户权限需要至少一个用户 OpenID';
    }
    if (isGroup && (enter || reply || openImagePicker)) {
      return '自动发送、指令引用和唤起选图仅支持单聊';
    }
    if (actionType != 2 && (enter || reply || openImagePicker)) {
      return '自动发送、指令引用和选图只适用于指令按钮';
    }
    if (groupId.isNotEmpty && actionType != 1) return '按钮分组仅适用于回调按钮';
    if (confirmContent.runes.length > 40 ||
        RegExp(
          r'https?://|www\.',
          caseSensitive: false,
        ).hasMatch(confirmContent)) {
      return '二次确认提示最多 40 个字符，不能包含 URL';
    }
    if (confirmText.runes.length > 4 || cancelText.runes.length > 4) {
      return '确认和取消按钮文字最多 4 个字符';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id.trim(),
    'render_data': {
      'label': label,
      if (visitedLabel.isNotEmpty) 'visited_label': visitedLabel,
      'style': style,
    },
    if (groupId.isNotEmpty) 'group_id': groupId,
    'action': {
      'type': actionType,
      'permission': {
        'type': permissionType,
        if (permissionType == 0) 'specify_user_ids': userIds,
      },
      'data': data,
      if (unsupportedTips.isNotEmpty) 'unsupport_tips': unsupportedTips,
      if (actionType == 2) ...{
        if (openImagePicker) 'anchor': 1,
        if (!openImagePicker && enter) 'enter': true,
        if (reply) 'reply': true,
      },
      if (confirmContent.isNotEmpty)
        'modal': {
          'content': confirmContent,
          if (confirmText.isNotEmpty) 'confirm_text': confirmText,
          if (cancelText.isNotEmpty) 'cancel_text': cancelText,
        },
    },
  };
}

class OutgoingMessage {
  final int type;
  final String content;
  final String? markdownTemplateId;
  final List<Map<String, String>>? templateParams;
  final int mediaFileType;
  final String mediaSource;
  final String fileInfo;
  final MessageSendOptions options;

  const OutgoingMessage({
    this.type = 0,
    this.content = '',
    this.markdownTemplateId,
    this.templateParams,
    this.mediaFileType = 1,
    this.mediaSource = '',
    this.fileInfo = '',
    this.options = const MessageSendOptions(),
  });

  String? validate({required bool isGroup}) {
    final optionsError = options.validate(isGroup: isGroup);
    if (optionsError != null) return optionsError;
    if (![0, 2, 7].contains(type)) return '仅支持文本、Markdown 和富媒体消息';
    if (options.keyboard != null && type != 2) return '按钮键盘需要和 Markdown 消息一起发送';
    if (options.forceVerifyImage && type != 2) return '图片转存校验仅适用于 Markdown 消息';
    if (type == 7) {
      if (![1, 2, 3, 4].contains(mediaFileType)) return '请选择有效的媒体类型';
      if (fileInfo.trim().isEmpty && mediaSource.trim().isEmpty) {
        return '请选择文件、填写公网 URL 或 file_info';
      }
    } else if (type == 2 && markdownTemplateId != null) {
      if (markdownTemplateId!.trim().isEmpty) return '请填写 Markdown 模板 ID';
      final keys = <String>{};
      for (final param in templateParams ?? <Map<String, String>>[]) {
        if ((param['key'] ?? '').trim().isEmpty ||
            (param['value'] ?? '').trim().isEmpty ||
            !keys.add(param['key']!.trim())) {
          return '模板参数不能为空或重名';
        }
        if ((param['value'] ?? '').contains(RegExp(r'[\r\n]'))) {
          return '模板参数不能换行，多行代码请使用自定义 Markdown';
        }
      }
    } else if (content.trim().isEmpty) {
      return '消息正文不能为空';
    }
    return null;
  }

  Map<String, dynamic> toPayload({
    String? messageId,
    String? eventId,
    int? sequence,
    String? referenceId,
    String? uploadedFileInfo,
  }) {
    final data = <String, dynamic>{'msg_type': type};
    switch (type) {
      case 0:
        data['content'] = content;
      case 2:
        data['markdown'] = {
          if (markdownTemplateId != null) ...{
            'custom_template_id': markdownTemplateId!.trim(),
            if (templateParams?.isNotEmpty == true)
              'params': [
                for (final param in templateParams!)
                  {
                    'key': param['key']!.trim(),
                    'values': [param['value']],
                  },
              ],
          } else
            'content': content,
          if (options.forceVerifyImage) 'force_verify_image_resource': true,
        };
      case 7:
        data['content'] = ' ';
        data['media'] = {
          'file_info':
              uploadedFileInfo ??
              (fileInfo.isNotEmpty ? fileInfo : '（上传后自动填入）'),
        };
    }
    if (options.keyboard != null) data['keyboard'] = options.keyboard!.toJson();
    final msgId =
        messageId ??
        (options.replyMode == ReplyMode.message
            ? options.messageId.trim()
            : '');
    final evtId =
        eventId ??
        (options.replyMode == ReplyMode.event ? options.eventId.trim() : '');
    if (msgId.isNotEmpty) data['msg_id'] = msgId;
    if (evtId.isNotEmpty) data['event_id'] = evtId;
    if (msgId.isNotEmpty || evtId.isNotEmpty) {
      data['msg_seq'] = sequence ?? options.sequence ?? 1;
    }
    final refId = referenceId ?? options.referenceId.trim();
    if (refId.isNotEmpty) data['message_reference'] = {'message_id': refId};
    return data;
  }
}
