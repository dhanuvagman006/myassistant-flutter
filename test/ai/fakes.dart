// Fakes shared by the lib/ai tests: a scripted model and a recording
// audio sink.
import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';
// ignore: implementation_imports
import 'package:firebase_ai/src/api.dart' show GroundingMetadata;
import 'package:myassistant/ai/model_port.dart';
import 'package:myassistant/ai/speech.dart';

GenerateContentResponse textChunk(String text, {FinishReason? finish, GroundingMetadata? grounding}) =>
    GenerateContentResponse([
      Candidate(Content('model', [TextPart(text)]), null, null, finish, null,
          groundingMetadata: grounding),
    ], null);

GenerateContentResponse partsChunk(List<Part> parts) => GenerateContentResponse([
      Candidate(Content('model', parts), null, null, null, null),
    ], null);

GenerateContentResponse audioResponse(List<int> bytes,
        {String mime = 'audio/L16;codec=pcm;rate=24000'}) =>
    GenerateContentResponse([
      Candidate(Content('model', [InlineDataPart(mime, Uint8List.fromList(bytes))]), null, null,
          FinishReason.stop, null),
    ], null);

/// A model that answers each request with the next script entry.
class FakeModel implements ModelPort {
  FakeModel([List<Object>? script]) : script = script ?? [];

  /// Each entry: a List<GenerateContentResponse> (streamed), a single
  /// GenerateContentResponse, an Exception to throw, or a function of the
  /// request returning one of those.
  final List<Object> script;
  final requests = <ModelRequest>[];

  /// Delay before each streamed chunk / generate answer.
  Duration delay = Duration.zero;

  Object _next(ModelRequest r) {
    requests.add(r);
    if (script.isEmpty) throw StateError('FakeModel: no answer scripted for request ${requests.length}');
    var entry = script.removeAt(0);
    if (entry is Object Function(ModelRequest)) entry = entry(r);
    return entry;
  }

  @override
  Stream<GenerateContentResponse> stream(ModelRequest request) async* {
    final entry = _next(request);
    if (entry is Exception || entry is Error) throw entry;
    if (entry is Stream<GenerateContentResponse>) {
      yield* entry;
      return;
    }
    if (entry is Future<GenerateContentResponse>) {
      yield await entry;
      return;
    }
    final chunks = entry is GenerateContentResponse
        ? [entry]
        : (entry as List).cast<GenerateContentResponse>();
    for (final c in chunks) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      yield c;
    }
  }

  /// How many times something asked for a warm-up.
  var warmUps = 0;

  @override
  Future<void> warmUp() async => warmUps++;

  @override
  Future<GenerateContentResponse> generate(ModelRequest request) async {
    final entry = _next(request);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (entry is Exception || entry is Error) throw entry;
    if (entry is Future<GenerateContentResponse>) return entry;
    return entry as GenerateContentResponse;
  }
}

/// An AudioSink that records what it was given.
class RecordingSink implements AudioSink {
  final played = <Uint8List>[];
  final rates = <int>[];
  var stops = 0;

  @override
  Future<void> play(Uint8List pcm16, {required int sampleRate}) async {
    played.add(pcm16);
    rates.add(sampleRate);
  }

  @override
  Future<void> stop() async => stops++;
}
