import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';

/// VOICE — its own screen, reached from Settings → Voice.
///
/// Six rows of voice names took as much room as everything else on the
/// settings page for a choice made once. The row on Settings names the
/// current voice; this is where it changes.
class VoicePickerScreen extends StatefulWidget {
  final List<(String, String, String)> voices;
  final String selectedId;
  const VoicePickerScreen({
    super.key,
    required this.voices,
    required this.selectedId,
  });

  @override
  State<VoicePickerScreen> createState() => _VoicePickerScreenState();
}

class _VoicePickerScreenState extends State<VoicePickerScreen> {
  late String _sel = widget.selectedId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(backgroundColor: Neon.bg, title: const Text('Voice')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 14),
            child: Text(
              'Tap a voice — it applies to your next conversation.',
              style: TextStyle(color: Neon.textLo, fontSize: 13.5),
            ),
          ),
          GroupedCard(
            children: [
              for (final (id, title, tagline) in widget.voices)
                AppleRow(
                  title: title,
                  subtitle: tagline,
                  trailing: _sel == id
                      ? Icon(Icons.check_rounded, color: Neon.violet, size: 20)
                      : const SizedBox(width: 20),
                  onTap: () {
                    setState(() => _sel = id);
                    Navigator.of(context).pop(id);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
