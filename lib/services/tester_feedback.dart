import 'package:flutter/services.dart';

import '../core/log.dart';

/// How a tap on Send feedback went, as far as the app can know.
enum FeedbackStart {
  /// The form is on its way. From here on the form speaks for itself.
  opened,

  /// No working internet, so the form was not started. Everything after
  /// the tap (signing in, finding this build, sending) needs it.
  offline,

  /// It could not start for any other reason: Firebase not started, no
  /// Android half, the app not on screen. None of those is the user's to
  /// fix, so what the app says about it makes no claim about the cause.
  unavailable,
}

/// SEND FEEDBACK — the You tab's way to tell the developer what to fix.
///
/// Owner, 2026-09-25: "yes add the send feedback button". The client gets
/// the app through Firebase App Distribution, so the form is that
/// service's own (Android side: TesterFeedbackBridge): what the client
/// writes lands in the Firebase console under the release it is about, as
/// Tester feedback — no inbox of ours, no server of ours.
///
/// Opens the form only. Nothing here checks for or installs updates; the
/// app's own updater stays the only one.
class TesterFeedback {
  TesterFeedback._();

  static const channel = MethodChannel('hari/feedback');

  /// Opens the feedback form. Never throws: a phone without the Android
  /// half (MissingPluginException) and a start the Android half refused
  /// (PlatformException) both come back as a [FeedbackStart] the caller
  /// turns into one toast. Only the Android half's "offline" code is
  /// [FeedbackStart.offline] (review, 2026-09-25: the old single toast
  /// blamed the internet for failures that never were the internet).
  static Future<FeedbackStart> start() async {
    try {
      final opened = await channel.invokeMethod<bool>('start') ?? false;
      return opened ? FeedbackStart.opened : FeedbackStart.unavailable;
    } on PlatformException catch (e) {
      AppLog.add('feedback', 'could not open: ${e.code} ${e.message ?? ''}');
      return e.code == 'offline'
          ? FeedbackStart.offline
          : FeedbackStart.unavailable;
    } on MissingPluginException {
      AppLog.add('feedback', 'could not open: no feedback channel');
      return FeedbackStart.unavailable;
    }
  }
}
