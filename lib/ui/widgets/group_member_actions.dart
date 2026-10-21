import 'package:flutter/material.dart';
import '../../core/bot_client.dart';
import '../../models/group_notice.dart';
import 'app_dialogs.dart';
import 'profile_avatar.dart';

enum _MemberAction { mention, mute, unmute, remove }

/// Shared by message avatars and group settings. Dialogs retain the original
/// account/credential generation; a bot switch cannot retarget an operation.
class GroupMemberActions {
  static final _active = Expando<Set<String>>();

  static Future<void> show(
    BuildContext context,
    BotClient bot,
    GroupTarget target,
    String memberId, {
    String name = '',
    String avatarUrl = '',
    VoidCallback? onMention,
  }) async {
    if (!bot.groups.isCurrent(target) || memberId.isEmpty) return;
    final key = '${target.appId}:${target.epoch}:${target.groupId}:$memberId';
    final active = _active[bot] ??= <String>{};
    if (!active.add(key)) return;
    try {
      final action = await AppDialogs.present<_MemberAction>(
        context,
        stillRelevant: () => context.mounted && bot.groups.isCurrent(target),
        builder: (_) => _MemberActionDialog(
          bot: bot,
          target: target,
          memberId: memberId,
          name: name,
          avatarUrl: avatarUrl,
          canMention: onMention != null,
        ),
      );
      if (action == null || !context.mounted || !bot.groups.isCurrent(target)) {
        return;
      }
      final member = {'member_openid': memberId, 'username': name};
      if (action == _MemberAction.mention) {
        onMention?.call();
      } else if (action == _MemberAction.remove) {
        await remove(context, bot, target, member);
      } else {
        await setMute(
          context,
          bot,
          target,
          member,
          remove: action == _MemberAction.unmute,
        );
      }
    } finally {
      active.remove(key);
    }
  }

  static Future<void> setMute(
    BuildContext context,
    BotClient bot,
    GroupTarget target,
    Map<String, dynamic> member, {
    bool remove = false,
  }) async {
    final id = groupText(member['member_openid']);
    var minutes = 10;
    final accepted = await AppDialogs.present<bool>(
      context,
      stillRelevant: () => context.mounted && bot.groups.isCurrent(target),
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(remove ? '解除成员禁言？' : '设置成员禁言'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  groupText(member['username']).isEmpty
                      ? id
                      : groupText(member['username']),
                ),
                if (!remove) ...[
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    initialValue: minutes,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '禁言时长'),
                    items: [
                      for (final (value, label) in [
                        (5, '5 分钟'),
                        (10, '10 分钟'),
                        (60, '1 小时'),
                        (1440, '1 天'),
                        (10080, '7 天'),
                        (43200, '30 天'),
                      ])
                        DropdownMenuItem(value: value, child: Text(label)),
                    ],
                    onChanged: (value) => update(() => minutes = value ?? 10),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(remove ? '确认解除' : '确认禁言'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !context.mounted) return;
    try {
      // Reload immediately before mutation. Never guess add/update from an old
      // page, and never turn a failed read into an empty mute list.
      final mute = remove ? null : await bot.groups.loadMute(target);
      final rows = mute?['members'];
      if (!remove && rows is! List) throw StateError('平台返回的禁言列表格式异常');
      final exists =
          rows is List &&
          rows.whereType<Map>().any((m) => m['member_openid'] == id);
      await bot.groups.setMemberMute(
        target,
        id,
        operation: remove
            ? 'del'
            : exists
            ? 'update'
            : 'add',
        expiresAt: remove
            ? null
            : DateTime.now().add(Duration(minutes: minutes)),
      );
      try {
        await bot.groups.loadMute(target);
      } catch (_) {
        /* Action already succeeded. */
      }
    } catch (error) {
      if (context.mounted) {
        await AppDialogs.show(
          context,
          error.toString(),
          title: '禁言设置未完成',
          error: true,
        );
      }
    }
  }

  static Future<void> remove(
    BuildContext context,
    BotClient bot,
    GroupTarget target,
    Map<String, dynamic> member,
  ) async {
    final id = groupText(member['member_openid']);
    final accepted = await AppDialogs.present<bool>(
      context,
      stillRelevant: () => context.mounted && bot.groups.isCurrent(target),
      builder: (dialog) => AlertDialog(
        title: const Text('将此成员移出群聊？'),
        content: SingleChildScrollView(
          child: Text(
            '${groupText(member['username']).isEmpty ? id : groupText(member['username'])}\n\n'
            '确认后会将该成员踢出当前群聊，不会加入群黑名单。此操作不能在管理器中撤销。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialog).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认移出'),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    try {
      await bot.groups.removeMember(target, id);
      if (context.mounted && bot.groups.isCurrent(target)) {
        await AppDialogs.show(context, '该成员已移出群聊，未加入群黑名单。', title: '移出成功');
      }
    } catch (error) {
      if (context.mounted) {
        await AppDialogs.show(
          context,
          error.toString(),
          title: '成员移出未完成',
          error: true,
        );
      }
    }
  }
}

class _MemberActionDialog extends StatefulWidget {
  final BotClient bot;
  final GroupTarget target;
  final String memberId, name, avatarUrl;
  final bool canMention;
  const _MemberActionDialog({
    required this.bot,
    required this.target,
    required this.memberId,
    required this.name,
    required this.avatarUrl,
    required this.canMention,
  });
  @override
  State<_MemberActionDialog> createState() => _MemberActionDialogState();
}

class _MemberActionDialogState extends State<_MemberActionDialog> {
  bool _loading = true, _muted = false;
  String? _error, _muteError;
  String _name = '';

  Future<void> _select(_MemberAction action) async {
    if (!widget.bot.groups.isCurrent(widget.target)) return;
    if (action == _MemberAction.mention || (!_loading && _error == null)) {
      Navigator.pop(context, action);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(_loading ? '正在检查权限' : '无法管理此成员'),
        content: Text(_loading ? '正在向 QQ 查询权限，请稍后重试。' : _error!),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final member = await widget.bot.groups.inspectModeratableMember(
        widget.target,
        widget.memberId,
      );
      _name = groupText(member['username']);
      try {
        final state = await widget.bot.groups.loadMute(widget.target);
        final members = state['members'];
        if (members is! List) throw StateError('平台返回的禁言列表格式异常');
        _muted = members.whereType<Map>().any(
          (m) => m['member_openid'] == widget.memberId,
        );
      } catch (_) {
        _muteError = '暂未获取禁言状态；提交时会重新查询。';
      }
    } catch (error) {
      _error = error.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.bot,
    builder: (context, _) {
      final current = widget.bot.groups.isCurrent(widget.target);
      final allowed = current && !_loading && _error == null;
      return AlertDialog(
        title: const Text('群成员操作'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ProfileAvatar(
                      name: _name.isEmpty ? widget.name : _name,
                      url: widget.avatarUrl,
                      radius: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _name.isNotEmpty
                            ? _name
                            : widget.name.isNotEmpty
                            ? widget.name
                            : '群成员',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                if (!current)
                  const Text('机器人已切换，请关闭后重新打开成员菜单。')
                else if (_loading)
                  const LinearProgressIndicator()
                else if (_error != null)
                  Text(
                    '暂不能执行群管理，点击下方操作可查看原因。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  )
                else ...[
                  Text(_muted ? '当前已被禁言' : _muteError ?? '可管理此普通成员'),
                  const SizedBox(height: 8),
                  const Text('禁言和移出需要机器人管理员权限及平台接口权限。'),
                ],
                if (widget.canMention && current) ...[
                  const SizedBox(height: 16),
                  ListTile(
                    leading: const Icon(Icons.alternate_email_rounded),
                    title: const Text('@ 此成员'),
                    subtitle: const Text('插入 Markdown，不会立即发送'),
                    onTap: () => _select(_MemberAction.mention),
                  ),
                ],
                if (current) ...[
                  ListTile(
                    leading: const Icon(Icons.mic_off_outlined),
                    title: const Text('设置禁言'),
                    textColor: allowed ? null : Theme.of(context).hintColor,
                    onTap: () => _select(_MemberAction.mute),
                  ),
                  if (_muted)
                    ListTile(
                      leading: const Icon(Icons.mic_none),
                      title: const Text('解除禁言'),
                      onTap: () => _select(_MemberAction.unmute),
                    ),
                  ListTile(
                    leading: Icon(
                      Icons.person_remove_outlined,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    title: const Text('踢出群聊'),
                    textColor: allowed ? null : Theme.of(context).hintColor,
                    onTap: () => _select(_MemberAction.remove),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}
