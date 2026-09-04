import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../design/neon_tokens.dart';
import '../services/app_feedback.dart';
import '../services/avatar_message_service.dart';

/// YOUR AVATAR IDENTITY — sender-side onboarding for personalized avatar
/// messages ("tell Ravi…" arriving as a video of YOU speaking it).
///
/// Order is deliberate: consent FIRST, assets second. The backend refuses
/// asset uploads without recorded consent, and revoking consent stops
/// rendering immediately. The screen never shows anyone else's identity —
/// there is nothing here to point at another person.
class AvatarIdentityScreen extends StatefulWidget {
  const AvatarIdentityScreen({super.key});

  @override
  State<AvatarIdentityScreen> createState() => _AvatarIdentityScreenState();
}

class _AvatarIdentityScreenState extends State<AvatarIdentityScreen> {
  Map<String, dynamic>? _profile;
  bool _busy = false;

  final AudioRecorder _rec = AudioRecorder();
  bool _recording = false;
  Timer? _recTimer;
  int _recSeconds = 0;

  static const _sampleScript =
      '“Hi, this is my voice. I’m recording a short sample so my assistant '
      'can speak messages to my friends in my own voice.”';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _recTimer?.cancel();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await AvatarMessageService.profile();
    if (mounted) setState(() => _profile = p);
  }

  bool get _consented => _profile?['consented'] == true;

  Future<void> _run(Future<bool> Function() op, String okMsg) async {
    setState(() => _busy = true);
    final ok = await op();
    if (mounted) {
      setState(() => _busy = false);
      AppFeedback.toast(ok ? okMsg : 'That didn’t work — please try again.');
    }
    await _load();
  }

  Future<void> _pickFace(ImageSource source) async {
    final x = await ImagePicker().pickImage(
        source: source, maxWidth: 1440, maxHeight: 1440, imageQuality: 92);
    if (x == null) return;
    await _run(() => AvatarMessageService.uploadFace(File(x.path)),
        'Photo saved — that face is you now.');
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      _recTimer?.cancel();
      final path = await _rec.stop();
      setState(() => _recording = false);
      if (path == null) return;
      await _run(() => AvatarMessageService.uploadVoice(File(path)),
          'Voice sample saved.');
      return;
    }
    if (!await _rec.hasPermission()) {
      AppFeedback.toast('Microphone permission is needed to record.');
      return;
    }
    final dir = await getTemporaryDirectory();
    await _rec.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 44100),
      path: '${dir.path}/voice_sample.m4a',
    );
    _recSeconds = 0;
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recSeconds++);
      if (_recSeconds >= 20) _toggleRecording(); // ~10-20s is plenty
    });
    setState(() => _recording = true);
  }

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        foregroundColor: Neon.textHi,
        elevation: 0,
        title: const Text('Your avatar identity'),
      ),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'When you ask your assistant to send someone a message, '
                  'they can see it as a short video of you — your face, '
                  'your voice — generated for exactly what you asked to '
                  'say. It is always labelled as AI-generated.',
                  style: TextStyle(
                      color: Neon.textLo, fontSize: 13.5, height: 1.45),
                ),
                const SizedBox(height: 20),

                _card(
                  icon: Icons.verified_user_rounded,
                  title: 'Consent',
                  subtitle: _consented
                      ? 'You have allowed your face and voice to be used '
                          'for your own outgoing messages. You can revoke '
                          'this at any time.'
                      : 'Before anything is stored, you must explicitly '
                          'allow the app to create an AI likeness of you. '
                          'It is only ever used for messages YOU send.',
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            _consented
                                ? AvatarMessageService.revokeConsent
                                : AvatarMessageService.grantConsent,
                            _consented ? 'Consent revoked.' : 'Consent recorded.'),
                    child: Text(_consented ? 'Revoke consent' : 'I consent'),
                  ),
                ),

                if (_consented) ...[
                  _card(
                    icon: Icons.face_rounded,
                    title: 'Your face',
                    subtitle: p['has_face'] == true
                        ? 'A reference photo is on file. Retake it any time '
                            '— a bright, front-facing photo works best.'
                        : 'Add one clear, front-facing photo. This is the '
                            'face your messages will wear.',
                    child: Row(children: [
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _pickFace(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_rounded, size: 18),
                        label: const Text('Camera'),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _pickFace(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_rounded, size: 18),
                        label: const Text('Gallery'),
                      ),
                    ]),
                  ),
                  _card(
                    icon: Icons.mic_rounded,
                    title: 'Your voice',
                    subtitle: p['has_voice'] == true
                        ? 'A voice sample is on file. Re-record any time in '
                            'a quiet room.'
                        : 'Record ~10 seconds of natural speech. Read this '
                            'aloud:\n\n$_sampleScript',
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _toggleRecording,
                      icon: Icon(
                          _recording
                              ? Icons.stop_rounded
                              : Icons.fiber_manual_record_rounded,
                          size: 18),
                      label: Text(_recording
                          ? 'Stop (${_recSeconds}s)'
                          : (p['has_voice'] == true
                              ? 'Re-record'
                              : 'Record sample')),
                    ),
                  ),
                  _card(
                    icon: Icons.play_circle_outline_rounded,
                    title: 'Send as avatar',
                    subtitle:
                        'When off, your messages go out as text and voice '
                        'only. Your stored photo and sample are unaffected.',
                    child: Switch(
                      value: p['enabled'] == true,
                      onChanged: _busy
                          ? null
                          : (v) => _run(() => AvatarMessageService.setEnabled(v),
                              v ? 'Avatar messages on.' : 'Avatar messages off.'),
                    ),
                  ),
                  _card(
                    icon: Icons.delete_outline_rounded,
                    title: 'Delete everything',
                    subtitle:
                        'Removes your photo, voice sample and any cloned '
                        'voice from our systems. Cannot be undone.',
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              final sure = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: const Text('Delete avatar identity?'),
                                  content: const Text(
                                      'Your photo, voice sample and cloned '
                                      'voice will be permanently removed.'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(c, false),
                                        child: const Text('Cancel')),
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(c, true),
                                        child: const Text('Delete')),
                                  ],
                                ),
                              );
                              if (sure == true) {
                                await _run(AvatarMessageService.deleteIdentity,
                                    'Avatar identity deleted.');
                              }
                            },
                      child: const Text('Delete'),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _card({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(Neon.rMd),
        border: Border.all(color: Neon.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: Neon.textHi, size: 20),
          const SizedBox(width: 10),
          Text(title,
              style: TextStyle(
                  color: Neon.textHi,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        Text(subtitle,
            style:
                TextStyle(color: Neon.textDim, fontSize: 12.5, height: 1.4)),
        const SizedBox(height: 12),
        child,
      ]),
    );
  }
}
