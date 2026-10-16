import 'package:shared_preferences/shared_preferences.dart';

/// Update options only. No device identity, statistics consent or telemetry token.
class UpdatePreferences {
  final SharedPreferences preferences;
  UpdatePreferences(this.preferences);
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
