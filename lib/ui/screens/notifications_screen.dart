import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../core/bot_client.dart';
import '../../models/group_notice.dart';
import '../../services/mobile_notifications.dart';
import '../../utils/profile_helpers.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/profile_avatar.dart';
import 'group_settings_screen.dart';

class NotificationsScreen extends StatefulWidget {
  final MobileNotifications? systemNotifications;
  final String? groupId;
  const NotificationsScreen({
    super.key,
    this.systemNotifications,
    this.groupId,
  });
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  String _filter = 'all';
  String? _group;
  bool _loading = false;
  final _cursors = <String, String>{};
  String _scope = '';
  bool _openingGroup = false;
  Future<void> _openGroup(BotClient bot, GroupNotice notice) async {
    if (_openingGroup || notice.appId != bot.config.appId) return;
    final ref = bot.groups.target(notice.groupId);
    setState(() => _openingGroup = true);
    try {
      var session = bot.sessions
          .where((s) => s.id == notice.groupId)
          .firstOrNull;
      if (session == null) {
        await bot.addSession(notice.groupId, isGroup: true);
        session = bot.sessions.where((s) => s.id == notice.groupId).firstOrNull;
      }
      if (!mounted || !bot.groups.isCurrent(ref) || session == null) return;
      final selected = session;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GroupSettingsScreen(session: selected),
        ),
      );
    } catch (error) {
      if (mounted) {
        await AppDialogs.show(
          context,
          error.toString(),
          title: '群聊设置未打开',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _openingGroup = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _group = widget.groupId;
    widget.systemNotifications?.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.systemNotifications?.removeListener(_changed);
    super.dispose();
  }

  String _name(BotClient bot, String id) =>
      bot.sessions.where((s) => s.id == id).firstOrNull?.name ?? '群聊 · $id';
  Future<void> _sync(BotClient bot, {bool next = false}) async {
    final id = _group;
    if (_loading || id == null) return;
    final ref = bot.groups.target(id);
    setState(() => _loading = true);
    try {
      final previous = next ? _cursors[id] ?? '' : '';
      final cursor = await bot.groups.syncRequests(ref, cursor: previous);
      if (!mounted || !bot.groups.isCurrent(ref)) return;
      setState(() => _cursors[id] = cursor == previous ? '' : cursor);
    } catch (error) {
      if (mounted) {
        await AppDialogs.show(
          context,
          error.toString(),
          title: '申请同步未完成',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _review(BotClient bot, GroupNotice notice, bool approve) async {
    var reason = '';
    var blacklist = false;
    final confirmed = await AppDialogs.present<bool>(
      context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(approve ? '同意入群申请？' : '拒绝入群申请？'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${notice.username}\n${_name(bot, notice.groupId)}'),
                  if (!approve) ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      onChanged: (value) => reason = value,
                      maxLength: 500,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: '拒绝理由（可选）'),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('同时加入该群黑名单'),
                      subtitle: const Text('这会改变 QQ 群的黑名单，仅在确有需要时勾选'),
                      value: blacklist,
                      onChanged: (value) =>
                          update(() => blacklist = value == true),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(
                approve
                    ? '确认同意'
                    : blacklist
                    ? '拒绝并拉黑'
                    : '确认拒绝',
              ),
            ),
          ],
        ),
      ),
    );
    final rejection = reason.trim();
    if (confirmed != true || !mounted) return;
    try {
      await bot.groups.approve(
        notice,
        approve: approve,
        reason: rejection,
        blacklist: blacklist,
      );
    } catch (error) {
      if (mounted) {
        await AppDialogs.show(
          context,
          error.toString(),
          title: '审核未完成',
          error: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bot = context.watch<BotClient>();
    final scope = '${bot.config.appId}:${bot.accountEpoch}';
    if (_scope != scope) {
      if (_scope.isNotEmpty) {
        _group = null;
        _filter = 'all';
      }
      _scope = scope;
      _cursors.clear();
    }
    final groups = {
      for (final session in bot.sessions.where((s) => s.sessionType == 1))
        session.id,
      ...bot.groups.notices.map((n) => n.groupId),
    };
    if (_group != null && !groups.contains(_group)) _group = null;
    final notices = bot.groups.notices
        .where(
          (notice) =>
              (_group == null || notice.groupId == _group) &&
              switch (_filter) {
                'unread' => !notice.isRead,
                'pending' => notice.pending,
                'processed' => [
                  'approved',
                  'declined',
                  'auto_approved',
                ].contains(notice.status),
                'joined' => notice.type == 'GROUP_MEMBER_ADD',
                'left' => notice.type == 'GROUP_MEMBER_REMOVE',
                _ => true,
              },
        )
        .toList();
    final mobile = widget.systemNotifications;
    return Scaffold(
      appBar: AppBar(
        title: const Text('消息与通知'),
        actions: [
          TextButton(
            onPressed: bot.groups.markAllRead,
            child: const Text('全部已读'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '群事件单独归档，不打断聊天',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      const Text('成员加入、退出和入群申请；同意或拒绝前都会再次确认。'),
                      if (mobile?.supported == true) ...[
                        const SizedBox(height: 16),
                        Card(
                          child: Column(
                            children: [
                              SwitchListTile(
                                title: const Text('手机系统通知'),
                                subtitle: Text(
                                  mobile!.error.isNotEmpty
                                      ? mobile.error
                                      : '在线收到消息或群事件时提醒；已屏蔽会话不提醒',
                                ),
                                value: mobile.enabled && mobile.permitted,
                                onChanged: mobile.busy
                                    ? null
                                    : (value) async {
                                        try {
                                          await mobile.setEnabled(value);
                                        } catch (_) {
                                          if (context.mounted) {
                                            await AppDialogs.show(
                                              context,
                                              mobile.error,
                                              title: '通知权限',
                                              error: true,
                                            );
                                          }
                                        }
                                      },
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  12,
                                ),
                                child: Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        'App 被系统挂起或关闭后无法保证接收；这不是离线推送服务。',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () async {
                                        try {
                                          await mobile.openSettings();
                                        } catch (_) {}
                                      },
                                      child: const Text('系统设置'),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: _group ?? '',
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '群聊筛选／同步入群申请',
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('全部群聊'),
                          ),
                          for (final id in groups)
                            DropdownMenuItem(
                              value: id,
                              child: Text(
                                _name(bot, id),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _loading
                            ? null
                            : (value) => setState(
                                () => _group = value == '' ? null : value,
                              ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (key, label) in [
                            ('all', '全部'),
                            ('unread', '未读'),
                            ('pending', '待审核'),
                            ('processed', '已处理'),
                            ('joined', '加入'),
                            ('left', '退出'),
                          ])
                            FilterChip(
                              label: Text(label),
                              selected: _filter == key,
                              onSelected: (_) => setState(() => _filter = key),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _loading || _group == null
                                ? null
                                : () => _sync(bot),
                            icon: _loading
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.sync),
                            label: const Text('同步入群申请'),
                          ),
                          if ((_cursors[_group] ?? '').isNotEmpty)
                            TextButton(
                              onPressed: _loading
                                  ? null
                                  : () => _sync(bot, next: true),
                              child: const Text('下一页申请'),
                            ),
                        ],
                      ),
                      if (groups.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text('收到群消息或群事件后，会在这里出现对应群聊。'),
                        ),
                    ],
                  ),
                ),
              ),
              if (notices.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('暂无符合筛选条件的群通知')),
                )
              else
                SliverList.builder(
                  itemCount: notices.length,
                  itemBuilder: (_, index) => _noticeCard(bot, notices[index]),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noticeCard(BotClient bot, GroupNotice notice) {
    final verification = notice.details['verify_info'];
    final questions =
        verification is Map && verification['review_qa_list'] is List
        ? verification['review_qa_list'] as List
        : const [];
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ProfileAvatar(
                  name: notice.username,
                  url: userProfileAvatar(
                    notice.appId,
                    notice.memberId,
                    const [],
                  ),
                  radius: 21,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${notice.title} · ${notice.statusLabel}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(notice.username, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                if (!notice.isRead)
                  const Icon(Icons.circle, size: 8, color: Colors.blue),
              ],
            ),
            const SizedBox(height: 10),
            Text(_name(bot, notice.groupId)),
            Text(
              DateFormat('yyyy-MM-dd HH:mm:ss').format(notice.time.toLocal()),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (groupText(notice.details['risk_tips']).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  groupText(notice.details['risk_tips']),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (verification is Map &&
                groupText(verification['verify_message']).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText('验证消息：${verification['verify_message']}'),
              ),
            for (final qa in questions.whereType<Map>())
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  '问：${groupText(qa['question'])}\n答：${groupText(qa['answer'])}',
                ),
              ),
            if (notice.details['apply_source'] == 'invited')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  '邀请人 OpenID：${groupText(notice.details['invited_by'])}',
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (notice.pending) ...[
                  FilledButton(
                    onPressed: bot.groups.isSaving
                        ? null
                        : () => _review(bot, notice, true),
                    child: const Text('同意'),
                  ),
                  OutlinedButton(
                    onPressed: bot.groups.isSaving
                        ? null
                        : () => _review(bot, notice, false),
                    child: const Text('拒绝'),
                  ),
                ],
                if (!notice.isRead)
                  TextButton(
                    onPressed: () => bot.groups.markRead(notice.id),
                    child: const Text('标为已读'),
                  ),
                TextButton(
                  onPressed: _openingGroup
                      ? null
                      : () => _openGroup(bot, notice),
                  child: const Text('群聊设置'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
