enum UpdateNode { auto, github, gitcode }

extension UpdateNodeLabel on UpdateNode {
  String get label => switch (this) {
    UpdateNode.auto => '自动优选',
    UpdateNode.github => 'GitHub · 国际',
    UpdateNode.gitcode => 'GitCode · 国内',
  };
}

class UpdateNodeStatus {
  final UpdateNode node;
  final int? milliseconds;
  final int? build;
  final String detail;
  const UpdateNodeStatus(
    this.node, {
    this.milliseconds,
    this.build,
    this.detail = '尚未检测',
  });
  bool get available => milliseconds != null && build != null;
}
