import 'package:flutter/foundation.dart';

/// App-wide "documents changed" signal.
///
/// Bumped after any successful upload, filing or deletion — by the screens
/// themselves and by the assistant engine when the agent files a capture
/// under a client. Open document lists (My documents, a case file) listen
/// and reload, so what the user sees always matches what the account
/// actually holds.
class DocumentEvents {
  DocumentEvents._();

  static final ValueNotifier<int> version = ValueNotifier<int>(0);

  static void bump() => version.value = version.value + 1;
}
