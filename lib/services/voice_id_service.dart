import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../core/log.dart';
import 'live_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  VoiceIdService — "only MY voice".
///
///  The user records ~8 seconds of speech once; a speaker-embedding model
///  (sherpa-onnx CAM++ zh/en, bundled, fully offline — the sample never
///  leaves the phone) turns it into a voiceprint stored locally. Live mode
///  then scores every utterance against it and silently drops other
///  people's speech before a single byte reaches the model.
///
///  Everything runs in a dedicated isolate: model load and per-utterance
///  embedding (~tens of ms) never touch the UI thread.
///
///  Fail-open by design: if the model can't load, scoring errors, or the
///  clip is too short to judge, the utterance is ACCEPTED. A wrongly
///  ignored owner reads as "the app is broken"; a rarely answered guest
///  does not.
/// ─────────────────────────────────────────────────────────────────────────
class VoiceIdService {
  VoiceIdService._();
  static final VoiceIdService instance = VoiceIdService._();

  static const _prefEnabled = 'voice_id_enabled';
  static const _prefProfile = 'voice_id_profile_v1';

  /// Cosine ≥ this = definitely the enrolled speaker.
  static const double acceptThreshold = 0.42;

  /// Soft floor for SHORT utterances ("yes", "stop") — embeddings from
  /// under a second of speech are noisy, so lean towards the owner.
  static const double softThreshold = 0.30;

  Float32List? _profile; // unit-normalized enrolled embedding
  bool _enabled = false;
  bool _loaded = false;

  Isolate? _isolate;
  SendPort? _worker;
  int _reqId = 0;
  final Map<int, Completer<Float32List?>> _pending = {};

  bool get enrolled => _profile != null;
  bool get gateEnabled => _enabled && enrolled;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      _enabled = p.getBool(_prefEnabled) ?? false;
      final b64 = p.getString(_prefProfile);
      if (b64 != null && b64.isNotEmpty) {
        final bytes = base64Decode(b64);
        _profile = Float32List.view(
            bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 4);
      }
    } catch (_) {}
  }

  Future<void> setEnabled(bool on) async {
    _enabled = on;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_prefEnabled, on);
    } catch (_) {}
    // A conversation may already be running — flip its gate live too.
    LiveService.instance.speakerGateEnabled = gateEnabled;
    if (on) unawaited(_ensureWorker()); // warm the model before first use
  }

  Future<void> clearEnrollment() async {
    _profile = null;
    _enabled = false;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_prefProfile);
      await p.setBool(_prefEnabled, false);
    } catch (_) {}
  }

  /// ── Worker isolate ────────────────────────────────────────────────────

  Future<bool> _ensureWorker() async {
    if (_worker != null) return true;
    try {
      final modelPath = await _materializeModel();
      final ready = ReceivePort();
      _isolate = await Isolate.spawn(
          _workerMain, [ready.sendPort, modelPath],
          debugName: 'voice-id');
      final results = ReceivePort();
      _worker = await ready.first as SendPort;
      _worker!.send(results.sendPort);
      results.listen((msg) {
        if (msg is List && msg.length == 2) {
          _pending.remove(msg[0] as int)?.complete(msg[1] as Float32List?);
        }
      });
      return true;
    } catch (e) {
      AppLog.add('voiceid', 'worker failed to start: $e');
      _worker = null;
      _isolate = null;
      return false;
    }
  }

  /// Copies the bundled model out of the APK once (native code needs a
  /// real file path).
  Future<String> _materializeModel() async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/speaker_id_v1.onnx');
    final data = await rootBundle.load('assets/models/speaker_id.onnx');
    if (!await f.exists() || await f.length() != data.lengthInBytes) {
      await f.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true);
    }
    return f.path;
  }

  static void _workerMain(List<dynamic> args) {
    final SendPort ready = args[0] as SendPort;
    final String modelPath = args[1] as String;
    sherpa.initBindings();
    final extractor = sherpa.SpeakerEmbeddingExtractor(
      config: sherpa.SpeakerEmbeddingExtractorConfig(
        model: modelPath,
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      ),
    );
    final inbox = ReceivePort();
    ready.send(inbox.sendPort);
    SendPort? results;
    inbox.listen((msg) {
      if (msg is SendPort) {
        results = msg;
        return;
      }
      if (msg is! List || msg.length != 2) return;
      final id = msg[0] as int;
      final pcm = msg[1] as Uint8List;
      Float32List? emb;
      try {
        final samples = Float32List(pcm.length ~/ 2);
        final bd = ByteData.sublistView(pcm);
        for (var i = 0; i < samples.length; i++) {
          samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
        }
        final st = extractor.createStream();
        st.acceptWaveform(samples: samples, sampleRate: 16000);
        st.inputFinished();
        if (extractor.isReady(st)) {
          final e = extractor.compute(st);
          emb = _normalize(e);
        }
        st.free();
      } catch (_) {}
      results?.send([id, emb]);
    });
  }

  static Float32List? _normalize(Float32List v) {
    if (v.isEmpty) return null;
    var n = 0.0;
    for (final x in v) {
      n += x * x;
    }
    n = math.sqrt(n);
    if (n < 1e-6) return null;
    final out = Float32List(v.length);
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] / n;
    }
    return out;
  }

  /// Frees the model isolate. Not called in normal use — the worker lives
  /// for the app's lifetime once warmed — but keeps resets possible.
  void shutdown() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _worker = null;
    for (final c in _pending.values) {
      c.complete(null);
    }
    _pending.clear();
  }

  Future<Float32List?> _embed(Uint8List pcm16k) async {
    if (!await _ensureWorker()) return null;
    final id = ++_reqId;
    final c = Completer<Float32List?>();
    _pending[id] = c;
    _worker!.send([id, pcm16k]);
    // The worker computes in tens of ms; a hung native call must never
    // wedge the mic pipeline.
    return c.future.timeout(const Duration(seconds: 4), onTimeout: () {
      _pending.remove(id);
      return null;
    });
  }

  static double _dot(Float32List a, Float32List b) {
    var s = 0.0;
    final n = math.min(a.length, b.length);
    for (var i = 0; i < n; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  /// ── Enrollment ────────────────────────────────────────────────────────

  /// [pcm16k] = PCM16 mono @16 kHz of the user reading the prompt (~8 s).
  /// Splits into overlapping windows, embeds each, checks they agree with
  /// each other (a noisy or multi-speaker sample fails), stores the mean.
  Future<String?> enroll(Uint8List pcm16k) async {
    const bytesPerSec = 32000;
    if (pcm16k.length < 4 * bytesPerSec) {
      return 'That was too short — please record again.';
    }
    const win = 3 * bytesPerSec, step = bytesPerSec + bytesPerSec ~/ 2;
    final embs = <Float32List>[];
    for (var off = 0;
        off + win <= pcm16k.length && embs.length < 6;
        off += step) {
      final e = await _embed(Uint8List.sublistView(pcm16k, off, off + win));
      if (e != null) embs.add(e);
    }
    if (embs.length < 2) {
      return "Couldn't read the recording — please try again.";
    }
    var pairSum = 0.0;
    var pairs = 0;
    for (var i = 0; i < embs.length; i++) {
      for (var j = i + 1; j < embs.length; j++) {
        pairSum += _dot(embs[i], embs[j]);
        pairs++;
      }
    }
    final selfSim = pairSum / pairs;
    if (selfSim < 0.45) {
      return 'The recording was unclear — find a quiet spot, hold the '
          'phone close, and speak naturally.';
    }
    final dim = embs.first.length;
    final mean = Float32List(dim);
    for (final e in embs) {
      for (var i = 0; i < dim; i++) {
        mean[i] += e[i];
      }
    }
    for (var i = 0; i < dim; i++) {
      mean[i] /= embs.length;
    }
    final prof = _normalize(mean);
    if (prof == null) return "Couldn't read the recording — please try again.";
    _profile = prof;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _prefProfile, base64Encode(prof.buffer.asUint8List()));
    } catch (_) {}
    AppLog.add('voiceid',
        'enrolled (${embs.length} windows, self-sim ${selfSim.toStringAsFixed(2)})');
    return null; // success
  }

  /// ── Verification ─────────────────────────────────────────────────────

  /// Cosine similarity of an utterance against the enrolled voice, or
  /// null when it cannot be judged (not enrolled, model unavailable, clip
  /// unreadable) — callers treat null as ACCEPT.
  Future<double?> scoreUtterance(Uint8List pcm16k) async {
    final prof = _profile;
    if (prof == null) return null;
    final e = await _embed(pcm16k);
    if (e == null) return null;
    return _dot(prof, e);
  }
}
