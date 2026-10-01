// THE ONE DOOR TO firebase_ai. Everything that asks a cloud model for
// something (the conversation, grounded search, speech, the transcription
// fallback) goes through a [ModelPort], so tests can hand the modules a
// fake and nothing in a unit test touches Firebase or the network.
import 'dart:async';
import 'dart:io';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/log.dart';

/// One request: which model, what it is told, and the conversation.
class ModelRequest {
  const ModelRequest({
    required this.model,
    required this.contents,
    this.system,
    this.tools,
    this.toolConfig,
    this.generationConfig,
  });

  final String model;
  final List<Content> contents;

  /// The system instruction (none when null or empty).
  final String? system;
  final List<Tool>? tools;
  final ToolConfig? toolConfig;
  final GenerationConfig? generationConfig;
}

abstract interface class ModelPort {
  /// The reply as it is generated.
  Stream<GenerateContentResponse> stream(ModelRequest request);

  /// The whole reply at once (transcription).
  Future<GenerateContentResponse> generate(ModelRequest request);

  /// Gets the tokens and the connection ready, so the next request does
  /// not pay for them. Best effort.
  Future<void> warmUp();
}

/// The real thing: the Gemini Developer API through Firebase AI Logic,
/// with this app's App Check attestation and the Firebase user signed in by
/// identity.dart on every request.
///
/// Speed (measured on the owner's phone, 2026-09-29): every request used to
/// fetch a fresh limited-use App Check token and open its own TLS
/// connection, a second or more each before the model saw a word. Now the
/// SDK's cached App Check token is used and ONE keep-alive client carries
/// every request, and [warmUp] fetches both tokens and opens the
/// connection when the assistant opens and when the orb is tapped.
class FirebaseModelPort implements ModelPort {
  FirebaseModelPort({FirebaseAI Function()? ai}) : _ai = ai ?? defaultAi;

  /// FirebaseAI.googleAI caches one instance per Firebase app, so this is
  /// cheap to call per request. App Check and Auth are not passed (that is
  /// deprecated): the SDK finds them on the Firebase app, where each
  /// registers itself the first time its `instance` is touched — done here
  /// so a request never goes out before they are.
  static FirebaseAI defaultAi() {
    FirebaseAppCheck.instance;
    FirebaseAuth.instance;
    return FirebaseAI.googleAI();
  }

  static const _host = 'https://firebasevertexai.googleapis.com/';

  /// One client for every model call: its connection stays open between
  /// the turns of a conversation.
  static final http.Client _client = IOClient(
    HttpClient()
      ..idleTimeout = const Duration(seconds: 90)
      ..connectionTimeout = const Duration(seconds: 10),
  );

  final FirebaseAI Function() _ai;
  DateTime? _warmedAt;

  GenerativeModel _model(ModelRequest r) {
    final system = r.system;
    return _ai().generativeModel(
      model: r.model,
      systemInstruction:
          system == null || system.trim().isEmpty ? null : Content.system(system),
      tools: r.tools,
      toolConfig: r.toolConfig,
      generationConfig: r.generationConfig,
      httpClient: _client,
    );
  }

  @override
  Stream<GenerateContentResponse> stream(ModelRequest request) =>
      _model(request).generateContentStream(request.contents);

  @override
  Future<GenerateContentResponse> generate(ModelRequest request) =>
      _model(request).generateContent(request.contents);

  @override
  Future<void> warmUp() async {
    final last = _warmedAt;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 20)) return;
    _warmedAt = DateTime.now();
    final started = DateTime.now();
    await Future.wait<void>([
      FirebaseAppCheck.instance.getToken().then((_) {}, onError: (Object e) {
        AppLog.add('ai', 'app check token not ready: ${e.runtimeType}');
      }),
      (FirebaseAuth.instance.currentUser?.getIdToken() ?? Future<String?>.value())
          .then((_) {}, onError: (Object e) {
        AppLog.add('ai', 'sign-in token not ready: ${e.runtimeType}');
      }),
      // Any answer will do: the point is the open, TLS-ready connection.
      _client.head(Uri.parse(_host)).timeout(const Duration(seconds: 8)).then((_) {},
          onError: (Object e) {
        AppLog.add('ai', 'model host not reached: ${e.runtimeType}');
      }),
    ]);
    AppLog.add('ai', 'warmed up in ${DateTime.now().difference(started).inMilliseconds} ms');
  }
}
