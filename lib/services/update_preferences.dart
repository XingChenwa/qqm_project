import 'package:shared_preferences/shared_preferences.dart';
import 'update_node.dart';

/// Update options only. No device identity, statistics consent or telemetry token.
class UpdatePreferences {
  final SharedPreferences preferences;
  UpdatePreferences(this.preferences);
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
  int get highestGitHubBuild =>
      preferences.getInt('updates_github_highest_build') ?? 0;
  Future<void> rememberGitHubBuild(int build) async {
    if (build > highestGitHubBuild) {
      await preferences.setInt('updates_github_highest_build', build);
    }
  }
}
