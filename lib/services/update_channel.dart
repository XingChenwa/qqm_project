enum UpdateChannel { stable, beta }

extension UpdateChannelLabel on UpdateChannel {
  String get label => this == UpdateChannel.stable ? '正式版' : 'Beta 测试版';
}
