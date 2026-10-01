// CLOUD — Gemini through Firebase AI Logic (firebase_ai): every turn,
// with the tools, the user's own data and attachments.
//
// A turn is: the server's system instruction + the recent conversation +
// the user's content (text, one image, PDF/audio/video bytes), with the
// server's tools declared. The reply streams; when the model calls tools,
// each call goes to the [ToolRunner] (the brain: /ai/tool, device actions)
// and its answer goes back as the function response, for up to
// maxToolRounds rounds, after which the model must answer in words.
// [search] is the same without tools, grounded in Google Search, keeping
// the pages it used.
import 'dart:async';

import 'package:firebase_ai/firebase_ai.dart';

import 'json_schema.dart';
import 'model_port.dart';
import 'types.dart';

/// Runs one tool call and returns what the model is told.
typedef ToolRunner = Future<Map<String, Object?>> Function(
    String name, Map<String, Object?> args);

class CloudRequest {
  const CloudRequest({
    required this.model,
    required this.text,
    this.system = '',
    this.history = const [],
    this.attachments = const [],
    this.tools = const [],
    this.maxToolRounds = 6,
    this.roundTimeout = const Duration(seconds: 30),
    this.firstTimeout,
    this.generationConfig,
  });

  final String model;
  final String text;
  final String system;
  final List<ChatTurn> history;

  /// Sent as inline data; each needs [AiAttachment.bytes].
  final List<AiAttachment> attachments;
  final List<AiToolSpec> tools;
  final int maxToolRounds;

  /// The most one model call (one round) may take.
  final Duration roundTimeout;

  /// The most a round may take to send anything back (a model stuck under
  /// load fails early, so its fallback can answer).
  final Duration? firstTimeout;
  final GenerationConfig? generationConfig;
}

sealed class CloudEvent {
  const CloudEvent();
}

/// More of the reply's words.
final class CloudTextDelta extends CloudEvent {
  const CloudTextDelta(this.text);
  final String text;
}

/// The model called a tool (the runner is about to run it).
final class CloudToolStarted extends CloudEvent {
  const CloudToolStarted(this.name, this.args);
  final String name;
  final Map<String, Object?> args;
}

/// The reply is complete.
final class CloudFinished extends CloudEvent {
  const CloudFinished({
    required this.text,
    this.sources = const [],
    this.searchSuggestionsHtml,
    this.toolRounds = 0,
    this.hitToolLimit = false,
  });

  final String text;

  /// Pages a grounded answer used.
  final List<SourceLink> sources;

  /// Google's "Search suggestions" chip HTML, which a grounded answer's UI
  /// is required to show (Gemini API grounding terms).
  final String? searchSuggestionsHtml;
  final int toolRounds;
  final bool hitToolLimit;
}

/// The model's answer was blocked (safety, recitation, a blocked prompt).
class CloudBlockedException implements Exception {
  const CloudBlockedException(this.reason);
  final String reason;

  @override
  String toString() => 'CloudBlockedException($reason)';
}

class CloudEngine {
  CloudEngine(this.port);

  final ModelPort port;

  /// The request's contents: the conversation (roles merged, starting with
  /// the user), then the user's attachments and words.
  static List<Content> buildContents(
    List<ChatTurn> history,
    String text,
    List<AiAttachment> attachments,
  ) {
    final out = <Content>[];
    String? role;
    var buf = <String>[];
    void flush() {
      if (role != null && buf.isNotEmpty) {
        out.add(Content(role, [TextPart(buf.join('\n'))]));
      }
      buf = <String>[];
    }

    for (final t in history) {
      if (t.text.trim().isEmpty) continue;
      final r = t.isUser ? 'user' : 'model';
      if (role == null && r == 'model') continue; // must start with the user
      if (r != role) {
        flush();
        role = r;
      }
      buf.add(t.text.trim());
    }
    flush();
    final parts = <Part>[
      for (final a in attachments)
        if (a.bytes != null) InlineDataPart(a.mimeType, a.bytes!),
      if (text.trim().isNotEmpty) TextPart(text.trim()),
    ];
    if (parts.isEmpty) parts.add(const TextPart('Hello'));
    // The history must not end with the user: merge into this turn.
    if (out.isNotEmpty && out.last.role == 'user') {
      out.add(Content('user', [...out.removeLast().parts, ...parts]));
    } else {
      out.add(Content('user', parts));
    }
    return out;
  }

  /// The web pages in a response's grounding metadata.
  static List<SourceLink> sourcesOf(GenerateContentResponse r) => [
        for (final c in r.candidates)
          for (final g in c.groundingMetadata?.groundingChunks ?? const <GroundingChunk>[])
            if (g.web?.uri case final uri? when uri.isNotEmpty)
              SourceLink(uri: uri, title: g.web?.title),
      ];

  /// One conversational turn with tools.
  Stream<CloudEvent> turn(CloudRequest r, {required ToolRunner runTool}) async* {
    final contents = buildContents(r.history, r.text, r.attachments);
    final declarations = [for (final t in r.tools) declarationFor(t)];
    final tools = declarations.isEmpty ? null : [Tool.functionDeclarations(declarations)];
    final text = StringBuffer();
    var rounds = 0;
    var hitLimit = false;
    while (true) {
      final lastRound = tools != null && rounds >= r.maxToolRounds;
      final request = ModelRequest(
        model: r.model,
        contents: List.of(contents),
        system: r.system,
        tools: tools,
        // Past the limit the model must answer in words.
        toolConfig: lastRound
            ? ToolConfig(functionCallingConfig: FunctionCallingConfig.none())
            : null,
        generationConfig: r.generationConfig,
      );
      final parts = <Part>[];
      await for (final resp in _within(port.stream(request), r.roundTimeout, first: r.firstTimeout)) {
        _throwIfBlocked(resp);
        final candidate = resp.candidates.isEmpty ? null : resp.candidates.first;
        if (candidate == null) continue;
        for (final p in candidate.content.parts) {
          parts.add(p);
          if (p is TextPart && p.isThought != true && p.text.isNotEmpty) {
            text.write(p.text);
            yield CloudTextDelta(p.text);
          }
        }
      }
      final calls = [
        for (final p in parts)
          if (p is FunctionCall && p.isThought != true) p,
      ];
      if (calls.isEmpty || tools == null) break;
      if (lastRound) {
        hitLimit = true;
        break;
      }
      // The model's own content goes back unchanged: Gemini's thought
      // signatures ride on these parts and a rebuilt call would lose them.
      contents.add(Content('model', parts));
      final responses = <FunctionResponse>[];
      for (final call in calls) {
        yield CloudToolStarted(call.name, call.args);
        Map<String, Object?> answer;
        try {
          answer = await runTool(call.name, call.args);
        } catch (e) {
          answer = {'ok': false, 'error': '$e'};
        }
        responses.add(FunctionResponse(call.name, answer, id: call.id));
      }
      contents.add(Content('user', responses));
      rounds++;
    }
    yield CloudFinished(text: text.toString(), toolRounds: rounds, hitToolLimit: hitLimit);
  }

  /// A fresh-facts answer grounded in Google Search (no function tools).
  Stream<CloudEvent> search(CloudRequest r) async* {
    final request = ModelRequest(
      model: r.model,
      contents: buildContents(r.history, r.text, r.attachments),
      system: r.system,
      tools: [Tool.googleSearch()],
      generationConfig: r.generationConfig,
    );
    final text = StringBuffer();
    final sources = <SourceLink>[];
    String? suggestions;
    await for (final resp in _within(port.stream(request), r.roundTimeout, first: r.firstTimeout)) {
      _throwIfBlocked(resp);
      for (final s in sourcesOf(resp)) {
        if (!sources.contains(s)) sources.add(s);
      }
      final entry = resp.candidates.isEmpty
          ? null
          : resp.candidates.first.groundingMetadata?.searchEntryPoint?.renderedContent;
      if (entry != null && entry.isNotEmpty) suggestions = entry;
      if (resp.candidates.isEmpty) continue;
      for (final p in resp.candidates.first.content.parts) {
        if (p is TextPart && p.isThought != true && p.text.isNotEmpty) {
          text.write(p.text);
          yield CloudTextDelta(p.text);
        }
      }
    }
    yield CloudFinished(
        text: text.toString(), sources: sources, searchSuggestionsHtml: suggestions);
  }

  static void _throwIfBlocked(GenerateContentResponse resp) {
    if (resp.candidates.isEmpty && resp.promptFeedback?.blockReason != null) {
      throw CloudBlockedException('${resp.promptFeedback!.blockReason}');
    }
    if (resp.candidates.isNotEmpty) {
      final reason = resp.candidates.first.finishReason;
      if (reason == FinishReason.safety || reason == FinishReason.recitation) {
        throw CloudBlockedException('$reason');
      }
    }
  }

  /// [source], failing with a TimeoutException if it has not finished
  /// within [limit] of being listened to, or sent nothing within [first].
  static Stream<T> _within<T>(Stream<T> source, Duration limit, {Duration? first}) {
    late final StreamController<T> out;
    StreamSubscription<T>? sub;
    Timer? timer;
    Timer? firstTimer;
    void expire(String what, Duration after) {
      timer?.cancel();
      firstTimer?.cancel();
      sub?.cancel();
      out.addError(TimeoutException(what, after));
      out.close();
    }

    out = StreamController<T>(
      onListen: () {
        timer = Timer(limit, () => expire('model call', limit));
        if (first != null && first < limit) {
          firstTimer = Timer(first, () => expire('model first reply', first));
        }
        sub = source.listen(
          (e) {
            firstTimer?.cancel();
            out.add(e);
          },
          onError: out.addError,
          onDone: () {
            timer?.cancel();
            firstTimer?.cancel();
            out.close();
          },
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () {
        timer?.cancel();
        firstTimer?.cancel();
        return sub?.cancel();
      },
    );
    return out.stream;
  }
}
