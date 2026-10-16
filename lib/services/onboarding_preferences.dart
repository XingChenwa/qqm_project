import 'package:shared_preferences/shared_preferences.dart';

/// Local UI preference only. Skipping is as permanent as finishing the guide.
class OnboardingPreferences {
  final SharedPreferences preferences;
  OnboardingPreferences(this.preferences);

  bool get completed => preferences.getBool('onboarding_completed') ?? false;

  Future<void> complete() async {
    if (!await preferences.setBool('onboarding_completed', true)) {
      throw StateError('Unable to save the local onboarding preference');
    }
  }
}
