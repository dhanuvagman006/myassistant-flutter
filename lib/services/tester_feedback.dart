import 'package:flutter/services.dart';

import '../core/log.dart';

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

  /// Opens the feedback form. False when it could not be opened — the
  /// caller says so once, in the app's one toast. Never throws: a phone
  /// without the Android half (MissingPluginException) and a start the
  /// Android half refused (PlatformException) read the same to the user.
  static Future<bool> start() async {
    try {
      return await channel.invokeMethod<bool>('start') ?? false;
    } on PlatformException catch (e) {
      AppLog.add('feedback', 'could not open: ${e.code} ${e.message ?? ''}');
      return false;
    } on MissingPluginException {
      AppLog.add('feedback', 'could not open: no feedback channel');
      return false;
    }
  }
}
