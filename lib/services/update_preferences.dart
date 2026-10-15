import 'package:shared_preferences/shared_preferences.dart';

/// Deliberately separate from bot configuration and its exports.
class UpdatePreferences {
  final SharedPreferences preferences;
  UpdatePreferences(this.preferences);

  bool get autoDownload => preferences.getBool('updates_auto_download') ?? true;
  // Keep an existing opt-out. Only a never-configured installation defaults on.
  bool get usageConsent => preferences.getBool('usage_consent_v1') ?? true;
  bool get usageNoticeSeen => preferences.getBool('usage_notice_v2') ?? false;
  String get installationId =>
      preferences.getString('usage_installation_id') ?? '';
  String get token => preferences.getString('usage_token') ?? '';
  String get pendingDeletion =>
      preferences.getString('usage_pending_delete') ?? '';
  Future<void> setAutoDownload(bool value) async =>
      preferences.setBool('updates_auto_download', value);
  Future<void> setUsageConsent(bool value) async =>
      preferences.setBool('usage_consent_v1', value);
  Future<void> markUsageNoticeSeen() async =>
      preferences.setBool('usage_notice_v2', true);
  Future<void> setInstallation(String id, String token) async {
    await preferences.setString('usage_installation_id', id);
    await preferences.setString('usage_token', token);
  }

  Future<void> setPendingDeletion(String value) async =>
      preferences.setString('usage_pending_delete', value);
  Future<void> clearInstallation() async {
    await preferences.remove('usage_installation_id');
    await preferences.remove('usage_token');
  }
}
