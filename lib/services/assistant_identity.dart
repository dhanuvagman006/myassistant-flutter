import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  ASSISTANT IDENTITY — the assistant's name, as THE USER chose it.
///
///  Settings → assistant name is the single source of truth (server-side
///  assistant_profiles.name). Nothing in the app may hardcode a name:
///  every visible mention reads [name] so renaming the assistant renames
///  it everywhere at once.
///
///  The last-known name is cached locally so the very first frame after a
///  cold start already shows the right name instead of flashing the
///  neutral default while the network round-trip completes.
/// ─────────────────────────────────────────────────────────────────────────
class AssistantIdentity {
  AssistantIdentity._();

  static const _prefsKey = 'assistant_display_name';

  /// Neutral default until the user names their assistant.
  static const fallback = 'Assistant';

  /// Listen to this to rebuild when the user renames the assistant.
  static final ValueNotifier<String> notifier = ValueNotifier(fallback);

  /// The current display name — what every screen should print.
  static String get name => notifier.value;

  /// Cached name immediately, fresh name from the profile when it arrives.
  /// Safe to call repeatedly; failures leave the current value in place.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_prefsKey)?.trim();
      if (cached != null && cached.isNotEmpty) notifier.value = cached;
    } catch (_) {}
    try {
      final p = await ApiService.getJson('/profile/full');
      final n = ((p?['assistant'] as Map?)?['name'] as String?)?.trim();
      if (n != null && n.isNotEmpty) await set(n);
    } catch (_) {}
  }

  /// Called by Settings after a successful save, so the whole app renames
  /// instantly without waiting for the next profile fetch.
  static Future<void> set(String n) async {
    final v = n.trim();
    if (v.isEmpty) return;
    notifier.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, v);
    } catch (_) {}
  }
}
