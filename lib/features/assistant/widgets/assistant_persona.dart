import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../design/neon_tokens.dart';
import '../../../services/auth_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  ASSISTANT PERSONA — who the assistant appears to be.
///
///  Gender already exists end-to-end (users.gender in Postgres, collected
///  at sign-up, exposed on AuthUser). This reads THAT — it does not add a
///  second gender system (§2).
///
///  Rule: the assistant presents as the opposite gender to the user.
///    user male   → female assistant
///    user female → male assistant
///    user other / unknown → the stored preference, else a neutral default
///
///  The resolved choice is persisted, so it stays stable across sessions
///  and the user can override it later without the profile flipping it
///  back.
/// ─────────────────────────────────────────────────────────────────────────
enum AssistantGender { female, male, neutral }

class AssistantPersona {
  final AssistantGender gender;
  final String displayName;

  const AssistantPersona._(this.gender, this.displayName);

  static const female = AssistantPersona._(AssistantGender.female, 'Hari');
  static const male = AssistantPersona._(AssistantGender.male, 'Hari');
  static const neutral = AssistantPersona._(AssistantGender.neutral, 'Hari');

  /// Portrait asset for this persona. Ships absent by design — a
  /// photorealistic face must be a licensed image, not something generated
  /// in code. Add the file and AssistantFace picks it up automatically.
  String get portraitAsset => switch (gender) {
        AssistantGender.female => 'assets/avatar/assistant_female.jpg',
        AssistantGender.male => 'assets/avatar/assistant_male.jpg',
        AssistantGender.neutral => 'assets/avatar/assistant_neutral.jpg',
      };

  /// Tint for the presence placeholder.
  Color get tint => switch (gender) {
        AssistantGender.female => Neon.violet,
        AssistantGender.male => Neon.cyan,
        AssistantGender.neutral => Neon.violet,
      };

  String get initial =>
      displayName.isEmpty ? 'A' : displayName.substring(0, 1).toUpperCase();

  String get key => gender.name;
}

class AssistantPersonaResolver {
  static const _prefsKey = 'assistant_persona_gender';
  static const _prefsSourceKey = 'assistant_persona_source';

  /// Resolves the persona for the signed-in user.
  ///
  /// A persona the USER chose explicitly always wins; otherwise it is
  /// derived from profile gender and cached so it survives restarts.
  static Future<AssistantPersona> resolve() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Explicit user preference — never overridden by profile data.
    final source = prefs.getString(_prefsSourceKey);
    final stored = prefs.getString(_prefsKey);
    if (source == 'user' && stored != null) return _fromKey(stored);

    // 2. Derive from the existing profile gender (opposite gender).
    final user = AuthService.instance.currentUser;
    final g = user?.gender?.toLowerCase();
    AssistantPersona? derived;
    if (g == 'male') {
      derived = AssistantPersona.female;
    } else if (g == 'female') {
      derived = AssistantPersona.male;
    }

    if (derived != null) {
      await prefs.setString(_prefsKey, derived.key);
      await prefs.setString(_prefsSourceKey, 'profile');
      return derived;
    }

    // 3. Nothing to derive from: reuse whatever was resolved before so the
    //    assistant doesn't change appearance between launches; else
    //    neutral, configurable later.
    if (stored != null) return _fromKey(stored);
    return AssistantPersona.neutral;
  }

  /// Explicit user override (settings). Persists and wins over profile.
  static Future<void> setPreference(AssistantGender g) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, g.name);
    await prefs.setString(_prefsSourceKey, 'user');
  }

  static AssistantPersona _fromKey(String k) => switch (k) {
        'female' => AssistantPersona.female,
        'male' => AssistantPersona.male,
        _ => AssistantPersona.neutral,
      };
}
