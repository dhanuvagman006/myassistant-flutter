import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_state.dart';

/// "Which Manish?" — the instant duplicate-contact picker.
///
/// Three people share a name, so the assistant must NOT guess and must not
/// spend a spoken round-trip asking. This sheet pops the moment the
/// ambiguity is known: one tap on a row places the call. Dismissing it
/// cancels — nothing is dialled.
class ContactPickerSheet extends StatelessWidget {
  final String spokenName;
  final List<ContactMatch> matches;

  const ContactPickerSheet({
    super.key,
    required this.spokenName,
    required this.matches,
  });

  /// Shows the picker over whatever is on screen. Resolves with the chosen
  /// contact, or null if the user dismissed it.
  static Future<ContactMatch?> show(
    BuildContext context, {
    required String spokenName,
    required List<ContactMatch> matches,
  }) {
    HapticFeedback.mediumImpact();
    return showModalBottomSheet<ContactMatch>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Neon.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) =>
          ContactPickerSheet(spokenName: spokenName, matches: matches),
    );
  }

  String get _title {
    final n = spokenName.trim();
    return n.isEmpty ? 'Which contact?' : 'Which $n?';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 2),
            child: Text(
              _title,
              style: TextStyle(
                color: Neon.textHi,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '${matches.length} contacts match. Tap the one to call.',
              style: TextStyle(color: Neon.textLo, fontSize: 13),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: matches.length,
              itemBuilder: (_, i) {
                final m = matches[i];
                return ListTile(
                  leading: CircleAvatar(
                    radius: 21,
                    backgroundColor: Neon.violet.withValues(alpha: 0.18),
                    child: Text(
                      m.name.isNotEmpty ? m.name[0].toUpperCase() : '?',
                      style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  title: Text(
                    m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    m.phone,
                    style: TextStyle(color: Neon.textLo, fontSize: 13),
                  ),
                  trailing: Icon(Icons.call_rounded, color: Neon.violet, size: 22),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    Navigator.of(context).pop(m);
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: TextStyle(color: Neon.textLo)),
            ),
          ),
        ],
      ),
    );
  }
}
