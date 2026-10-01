// LOCAL TOOLS — tools that run IN THE APP, not on the server.
//
// Most tools touch server data, other people, money, memory or the audit
// ledger, so they run on the server (POST /ai/tool). Some belong to the
// phone alone — a screen's own state, a timer on the counter, the step a
// recipe is on — and a round trip to the server would only add latency.
// A feature registers those here: a JSON-schema declaration the cloud
// model sees beside the server's tools, and a handler the brain runs
// locally instead of POST /ai/tool. A result may carry a deviceAction,
// performed by the engine exactly like a server tool's.
//
// A server tool of the same name always wins: the server's gates are never
// shadowed by the app. Local tools are offered only while [LocalTool.
// available] says so (e.g. while the feature's screen is open).
import 'dart:async';

import 'types.dart';

/// What a local tool hands back.
class LocalToolResult {
  const LocalToolResult({
    this.ok = true,
    this.result = const {},
    this.deviceAction,
    this.error,
  });

  const LocalToolResult.failed(String this.error)
      : ok = false,
        result = const {},
        deviceAction = null;

  final bool ok;

  /// What the model is handed as the function response.
  final Map<String, Object?> result;

  /// Something the PHONE must do (the same shapes the server sends).
  final Map<String, dynamic>? deviceAction;
  final String? error;

  Map<String, Object?> toFunctionResponse() => {
        ...result,
        if (!result.containsKey('ok')) 'ok': ok,
        if (!ok && error != null && !result.containsKey('error')) 'error': error,
      };
}

/// The turn a local tool runs in.
class LocalToolCall {
  const LocalToolCall({required this.name, required this.args, required this.userText});

  final String name;
  final Map<String, Object?> args;

  /// What the user said this turn.
  final String userText;
}

typedef LocalToolHandler = Future<LocalToolResult> Function(LocalToolCall call);

class LocalTool {
  const LocalTool({required this.spec, required this.handler, this.available});

  /// Name, description and parameters (a JSON Schema object), exactly as a
  /// server tool is declared.
  final AiToolSpec spec;
  final LocalToolHandler handler;

  /// Offered only while this says so (null: always).
  final bool Function()? available;

  String get name => spec.name;
  bool get isAvailable => available?.call() ?? true;
}

class LocalToolRegistry {
  final _tools = <String, LocalTool>{};

  /// Adds (or replaces) a tool. Returns a function that removes it again,
  /// for a feature's dispose().
  void Function() register(LocalTool tool) {
    _tools[tool.name] = tool;
    return () {
      if (identical(_tools[tool.name], tool)) _tools.remove(tool.name);
    };
  }

  void unregister(String name) => _tools.remove(name);

  void clear() => _tools.clear();

  bool get isEmpty => _tools.isEmpty;

  /// The tools on offer right now.
  List<LocalTool> available() => [
        for (final t in _tools.values)
          if (t.isAvailable) t,
      ];

  LocalTool? operator [](String name) => _tools[name];

  /// Runs [call] through its tool. Never throws: a failure, a missing tool
  /// or a handler that takes longer than [timeout] comes back as ok ==
  /// false with the reason, which the model is told.
  Future<LocalToolResult> run(LocalToolCall call, {Duration timeout = const Duration(seconds: 25)}) async {
    final tool = _tools[call.name];
    if (tool == null || !tool.isAvailable) {
      return const LocalToolResult.failed('That tool is not available right now.');
    }
    try {
      return await tool.handler(call).timeout(timeout);
    } on TimeoutException {
      return const LocalToolResult.failed('That took too long on the phone.');
    } catch (e) {
      return LocalToolResult.failed('$e');
    }
  }
}
