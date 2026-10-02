import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../ai/config.dart';
import '../ai/model_port.dart';
import '../ai/speech.dart';
import '../core/log.dart';
import 'audio/pcm_player.dart';

/// THE GREETING IN THE ASSISTANT'S OWN VOICE.
///
/// His call, 2026-09-20: "I want the agent's own voice… let the API say
/// it, or record the same voice instead of playing some low quality
/// audio." So it is SYNTHESISED ONCE by the same Gemini TTS the assistant
/// speaks through (lib/ai/speech.dart, Firebase AI Logic — the voice and
/// language from /ai/config), cached on disk, and played through the app's
/// PCM player on every later tap: one model call per voice, instant and
/// identical after that. No model writes it — the words are fixed.
///
/// IT NEVER FALLS BACK TO THE DEVICE VOICE. A greeting that sounds wrong
/// is what he asked to remove, so an uncached greeting is simply silent
/// (the listening chime still marks the moment) and warms itself for next
/// time.
class GreetingVoice {
  GreetingVoice({
    SpeechEngine? speech,
    AudioSink? sink,
    AiConfig Function()? config,
    Future<Directory> Function()? directory,
  })  : _speechOverride = speech,
        _sinkOverride = sink,
        _config = config ?? (() => AiConfigStore.instance.current),
        _directory = directory ?? getApplicationSupportDirectory;

  static final GreetingVoice instance = GreetingVoice();

  final SpeechEngine? _speechOverride;
  final AudioSink? _sinkOverride;
  final AiConfig Function() _config;
  final Future<Directory> Function() _directory;

  SpeechEngine? _speechMade;
  SpeechEngine get _speech =>
      _speechOverride ?? (_speechMade ??= SpeechEngine(port: ModelPorts.cloud(), config: _config));
  AudioSink get _sink => _sinkOverride ?? PcmPlayer.instance;

  static const _magic = [0x50, 0x43, 0x4D, 0x31]; // "PCM1", then the rate

  /// One file per wording AND voice: a new voice is a new greeting.
  Future<File> _fileFor(String text) async {
    final m = _config().models;
    final key = sha1
        .convert(utf8.encode('${m.tts}|${m.ttsVoice}|${m.ttsLanguage}|$text'))
        .toString()
        .substring(0, 16);
    return File('${(await _directory()).path}/greet_$key.pcm');
  }

  /// Synthesise and cache, if it is not already there. Safe to call often.
  Future<void> prewarm(String text) async {
    if (text.trim().isEmpty) return;
    try {
      final f = await _fileFor(text);
      // A truncated or empty file is worse than none — make it again.
      if (await f.exists() && await f.length() > 2000) return;
      final pcm = BytesBuilder(copy: false);
      var rate = 24000;
      await for (final c in _speech.synthesizeChunks(text)) {
        pcm.add(c.pcm);
        rate = c.sampleRate;
      }
      if (pcm.length < 2000) return;
      final head = ByteData(8);
      for (var i = 0; i < 4; i++) {
        head.setUint8(i, _magic[i]);
      }
      head.setUint32(4, rate, Endian.little);
      await f.writeAsBytes([...head.buffer.asUint8List(), ...pcm.takeBytes()], flush: true);
      AppLog.add('greeting', 'cached "$text"');
    } catch (e) {
      AppLog.add('greeting', 'prewarm failed: $e');
    }
  }

  /// Plays the cached greeting. False when nothing was cached — the caller
  /// stays silent rather than using another voice.
  Future<bool> play(String text) async {
    if (text.trim().isEmpty) return false;
    try {
      final f = await _fileFor(text);
      if (!await f.exists() || await f.length() < 2000) {
        unawaited(prewarm(text)); // ready for the next tap
        return false;
      }
      final bytes = await f.readAsBytes();
      final ok = bytes.length > 8 && [for (var i = 0; i < 4; i++) bytes[i]].join() == _magic.join();
      if (!ok) return false;
      final rate = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
      await _sink.play(Uint8List.sublistView(bytes, 8), sampleRate: rate);
      return true;
    } catch (e) {
      AppLog.add('greeting', 'play failed: $e');
      return false;
    }
  }

  /// Drop every cached greeting — called when the user picks a different
  /// voice, so the next tap is greeted in the voice they just chose.
  Future<void> clear() async {
    try {
      final dir = await _directory();
      for (final e in dir.listSync()) {
        final name = e.uri.pathSegments.isEmpty ? '' : e.uri.pathSegments.last;
        if (e is File && name.startsWith('greet_') &&
            (name.endsWith('.pcm') || name.endsWith('.wav'))) {
          try {
            await e.delete();
          } catch (_) {/* best effort */}
        }
      }
      AppLog.add('greeting', 'cache cleared');
    } catch (_) {/* nothing cached is a fine outcome */}
  }
}
