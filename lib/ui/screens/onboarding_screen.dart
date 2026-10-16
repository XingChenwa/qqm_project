import 'package:flutter/material.dart';

import '../widgets/app_dialogs.dart';
import '../widgets/app_logo.dart';

class OnboardingScreen extends StatefulWidget {
  final Future<void> Function(bool openConnection) onFinished;
  final bool replay;
  const OnboardingScreen({
    super.key,
    required this.onFinished,
    this.replay = false,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;
  bool _finishing = false;
  static const _content = [
    (
      icon: Icons.qr_code_2_rounded,
      title: '先接入你的机器人',
      description: '用熟悉的中文界面，把连接、消息和插件放在一起。',
      tips: [
        ('扫码连接优先', '在设置中生成二维码，用手机 QQ 确认授权，再保存并连接。'),
        ('也能手动配置', '切换到第二种方式，填写 QQ 开放平台的 AppID 和机器人密钥。'),
        ('使用官方机器人', '这不是个人 QQ 登录工具，扫码授权不会绕过平台权限。'),
      ],
    ),
    (
      icon: Icons.forum_outlined,
      title: '按你的节奏聊天',
      description: '连接后，收到的群聊和单聊会自动出现在会话列表。',
      tips: [
        ('消息不打断阅读', '收到新消息保留阅读位置，点击新消息入口再查看；发送成功后定位到最新。'),
        (
          'Markdown 独立编辑',
          '在输入区切换 Markdown，编辑、预览后发送。桌面 Enter 发送，Ctrl + Enter 换行。',
        ),
        ('先确认平台权限', '群内免 @ 需要开通接收所有消息；Markdown、媒体和按钮也需要对应权限。'),
      ],
    ),
    (
      icon: Icons.extension_outlined,
      title: '让机器人多点玩法',
      description: '打开“插件”，配置并启用需要的能力。',
      tips: [
        ('从六个内置插件开始', '帮助、天气、随机玩法、翻译、签到积分和群互动；天气与翻译需自备服务 Key。'),
        ('试试自己的命令', '发送 /帮助、/签到、/骰子 2d6，或在工作台试运行规则。积分与运势仅供娱乐。'),
        ('想开发，也留好接口', '“写插件”中编辑 JSON / YAML、校验和安装，复杂逻辑可以接入自己的 HTTP 服务。'),
      ],
    ),
    (
      icon: Icons.rocket_launch_outlined,
      title: '准备好了，开始吧',
      description: '随时可在“设置 → 关于 → 重新查看使用引导”回顾这些步骤。',
      tips: [
        ('把凭据留给自己', '密钥不发群、不贴截图；导出配置可能包含密钥，请妥善保管。'),
        ('遇到问题，看运行日志', '日志支持全部复制和导出 TXT / LOG，反馈前先去掉密钥和个人内容。'),
        ('手机后台有系统限制', '切到后台后，连接可能被系统暂停；返回应用后查看连接状态。'),
      ],
    ),
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _finish(bool openConnection) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    try {
      await widget.onFinished(openConnection);
    } catch (_) {
      if (mounted) AppDialogs.show(context, '暂时无法完成引导，请再试一次。', error: true);
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  void _move(int page) {
    _pages.animateToPage(
      page,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _content.length - 1;
    final color = Theme.of(context).colorScheme.primary;
    return PopScope(
      canPop: widget.replay,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish(false);
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                    child: Row(
                      children: [
                        const AppLogo(size: 40),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'QQ机器人管理器',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        TextButton(
                          onPressed: _finishing ? null : () => _finish(false),
                          child: Text(widget.replay ? '返回工作台' : '跳过引导'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PageView.builder(
                      controller: _pages,
                      itemCount: _content.length,
                      onPageChanged: (value) => setState(() => _page = value),
                      itemBuilder: (context, index) {
                        final item = _content[index];
                        return SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 620),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 72,
                                    height: 72,
                                    decoration: BoxDecoration(
                                      color: color.withValues(alpha: .08),
                                      borderRadius: BorderRadius.circular(22),
                                    ),
                                    child: Icon(
                                      item.icon,
                                      size: 38,
                                      color: color,
                                    ),
                                  ),
                                  const SizedBox(height: 22),
                                  Text(
                                    '使用引导 · ${index + 1} / ${_content.length}',
                                    style: TextStyle(
                                      color: color,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    item.title,
                                    style: const TextStyle(
                                      fontSize: 29,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    item.description,
                                    style: TextStyle(
                                      fontSize: 14,
                                      height: 1.8,
                                      color: Theme.of(context).hintColor,
                                    ),
                                  ),
                                  const SizedBox(height: 22),
                                  for (final (title, body) in item.tips)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 20,
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 3,
                                            ),
                                            child: Icon(
                                              Icons.check_circle_outline,
                                              size: 18,
                                              color: color,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  title,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                                const SizedBox(height: 5),
                                                Text(
                                                  body,
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    height: 1.8,
                                                    color: Theme.of(
                                                      context,
                                                    ).hintColor,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (
                              var index = 0;
                              index < _content.length;
                              index++
                            )
                              Semantics(
                                label: '第 ${index + 1} 步',
                                selected: _page == index,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: _finishing ? null : () => _move(index),
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Container(
                                      width: _page == index ? 24 : 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                        color: _page == index
                                            ? color
                                            : color.withValues(alpha: .2),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 12,
                          runSpacing: 10,
                          children: [
                            if (_page > 0)
                              OutlinedButton(
                                onPressed: _finishing
                                    ? null
                                    : () => _move(_page - 1),
                                child: const Text('上一步'),
                              ),
                            FilledButton(
                              onPressed: _finishing
                                  ? null
                                  : () =>
                                        last ? _finish(true) : _move(_page + 1),
                              child: Text(
                                _finishing
                                    ? '正在进入…'
                                    : last
                                    ? '开始接入机器人'
                                    : '下一步',
                              ),
                            ),
                            if (last)
                              TextButton(
                                onPressed: _finishing
                                    ? null
                                    : () => _finish(false),
                                child: const Text('先进入工作台'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
