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
  final double? bytesPerSecond;
  final int sampleBytes;
  final bool? transferAvailable;
  final String detail;
  const UpdateNodeStatus(
    this.node, {
    this.milliseconds,
    this.build,
    this.bytesPerSecond,
    this.sampleBytes = 0,
    this.transferAvailable,
    this.detail = '尚未检测',
  });
  bool get available => milliseconds != null && build != null;
  String? get speedLabel {
    final speed = bytesPerSecond;
    if (speed == null) return null;
    return speed >= 1024 * 1024
        ? '${(speed / (1024 * 1024)).toStringAsFixed(1)} MB/s'
        : '${(speed / 1024).toStringAsFixed(0)} KB/s';
  }
}
