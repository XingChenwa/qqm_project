import 'package:shared_preferences/shared_preferences.dart';
import 'update_node.dart';
import 'update_channel.dart';

/// Update options only. No device identity, statistics consent or telemetry token.
class UpdatePreferences {
  final SharedPreferences preferences;
  final UpdateChannel defaultChannel;
  UpdatePreferences(
    this.preferences, {
    this.defaultChannel = UpdateChannel.stable,
  });
  UpdateChannel get channel => UpdateChannel.values.firstWhere(
    (channel) => channel.name == preferences.getString('updates_channel'),
    orElse: () => defaultChannel,
  );
  Future<void> setChannel(UpdateChannel channel) async {
    if (!await preferences.setString('updates_channel', channel.name)) {
      throw StateError('无法保存更新渠道');
    }
  }

  UpdateNode get node => UpdateNode.values.firstWhere(
    (node) => node.name == preferences.getString('updates_node'),
    orElse: () => UpdateNode.auto,
  );
  Future<void> setNode(UpdateNode node) async {
    if (!await preferences.setString('updates_node', node.name)) {
      throw StateError('无法保存更新线路');
    }
  }

  bool get autoDownload => preferences.getBool('updates_auto_download') ?? true;
  Future<void> setAutoDownload(bool value) async =>
      preferences.setBool('updates_auto_download', value);
  int get highestGitHubBuild => preferences.getInt(_buildKey) ?? 0;
  String get _buildKey => channel == UpdateChannel.stable
      ? 'updates_github_highest_build'
      : 'updates_beta_highest_build';
  Future<void> rememberGitHubBuild(int build) async {
    if (build > highestGitHubBuild) {
      if (!await preferences.setInt(_buildKey, build)) {
        throw StateError('无法保存更新版本记录');
      }
    }
  }
}
