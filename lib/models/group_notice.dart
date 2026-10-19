import 'dart:convert';
import 'package:crypto/crypto.dart';

String groupText(Object? value, [int max = 4096]) {
  final text = value is String || value is num ? value.toString() : '';
  return text.length > max ? text.substring(0, max) : text;
}

/// An account-scoped platform event, deliberately separate from chat history.
class GroupNotice {
  final String id, appId, groupId, memberId, username, type, requestId, status;
  final DateTime time;
  final bool isRead;
  final Map<String, dynamic> details;
  const GroupNotice({
    required this.id,
    required this.appId,
    required this.groupId,
    required this.memberId,
    required this.username,
    required this.type,
    required this.time,
    this.requestId = '',
    this.status = 'info',
    this.isRead = false,
    this.details = const {},
  });

  bool get pending =>
      type == 'GROUP_JOIN_REQUEST' &&
      status == 'pending' &&
      requestId.isNotEmpty &&
      memberId.isNotEmpty;
  String get title => switch (type) {
    'GROUP_JOIN_REQUEST' => '入群申请',
    'GROUP_MEMBER_ADD' => '成员加入',
    'GROUP_MEMBER_REMOVE' => '成员退出或被移出',
    _ => '群通知',
  };
  String get statusLabel => switch (status) {
    'pending' => '待审核',
    'approved' => '已同意',
    'declined' => '已拒绝',
    'auto_approved' => '平台已自动同意',
    _ => '通知',
  };
  GroupNotice copyWith({bool? isRead, String? status}) => GroupNotice(
    id: id,
    appId: appId,
    groupId: groupId,
    memberId: memberId,
    username: username,
    type: type,
    time: time,
    requestId: requestId,
    status: status ?? this.status,
    isRead: isRead ?? this.isRead,
    details: details,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'appId': appId,
    'groupId': groupId,
    'memberId': memberId,
    'username': username,
    'type': type,
    'time': time.toUtc().toIso8601String(),
    'requestId': requestId,
    'status': status,
    'isRead': isRead,
    'details': details,
  };
  factory GroupNotice.fromMap(Map<String, dynamic> map) => GroupNotice(
    id: groupText(map['id']),
    appId: groupText(map['appId']),
    groupId: groupText(map['groupId']),
    memberId: groupText(map['memberId']),
    username: groupText(map['username']),
    type: groupText(map['type']),
    time:
        DateTime.tryParse(groupText(map['time'])) ??
        DateTime.fromMillisecondsSinceEpoch(0),
    requestId: groupText(map['requestId']),
    status: groupText(map['status']),
    isRead: map['isRead'] == true,
    details: map['details'] is Map
        ? Map<String, dynamic>.from(map['details'])
        : const {},
  );

  static GroupNotice? fromEvent(
    String appId,
    String type,
    Map<String, dynamic> data, {
    String fallbackName = '',
  }) {
    if (![
      'GROUP_JOIN_REQUEST',
      'GROUP_MEMBER_ADD',
      'GROUP_MEMBER_REMOVE',
    ].contains(type)) {
      return null;
    }
    final group = groupText(data['group_openid'], 512),
        member = groupText(data['member_openid'], 512);
    if (appId.isEmpty || group.isEmpty || member.isEmpty) return null;
    final requestId = groupText(data['join_request_id']);
    final timestamp = data['timestamp'];
    final time = timestamp is num
        ? DateTime.fromMillisecondsSinceEpoch((timestamp * 1000).toInt())
        : DateTime.tryParse(groupText(data['apply_at'] ?? timestamp)) ??
              DateTime.now();
    final verify = data['verify_info'];
    final details = <String, dynamic>{
      'risk_tips': groupText(data['risk_tips']),
      'apply_source': groupText(data['apply_source']),
      'invited_by': groupText(data['invited_by']),
      'bot': data['bot'] == true,
      if (verify is Map)
        'verify_info': {
          'method': groupText(verify['method']),
          'verify_message': groupText(verify['verify_message']),
          'review_qa_list': [
            for (final qa
                in (verify['review_qa_list'] is List
                        ? verify['review_qa_list'] as List
                        : const [])
                    .take(30))
              if (qa is Map)
                {
                  'question': groupText(qa['question']),
                  'answer': groupText(qa['answer']),
                },
          ],
        },
    };
    final eventKey = groupText(data['_eventId']).isNotEmpty
        ? data['_eventId']
        : jsonEncode([
            type,
            group,
            member,
            data['timestamp'],
            data['apply_at'],
          ]);
    final id = type == 'GROUP_JOIN_REQUEST' && requestId.isNotEmpty
        ? sha256
              .convert(utf8.encode(jsonEncode([type, group, requestId])))
              .toString()
        : sha256.convert(utf8.encode(eventKey.toString())).toString();
    final name = groupText(data['username'], 256);
    return GroupNotice(
      id: id,
      appId: appId,
      groupId: group,
      memberId: member,
      username: name.isNotEmpty
          ? name
          : (fallbackName.isNotEmpty ? fallbackName : member),
      type: type,
      time: time,
      requestId: requestId,
      details: details,
      status: type != 'GROUP_JOIN_REQUEST'
          ? 'info'
          : data['auto_approved'] is Map
          ? 'auto_approved'
          : requestId.isNotEmpty
          ? 'pending'
          : 'info',
    );
  }
}

class GroupTarget {
  final String appId, groupId;
  final int epoch;
  const GroupTarget(this.appId, this.groupId, this.epoch);
}
