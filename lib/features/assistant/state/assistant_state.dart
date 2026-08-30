/// Assistant state machine + typed models for the event contract.
///
/// The phases mirror the backend's `assistant_state` events one-to-one, so
/// the UI can render EXACTLY what the assistant is doing at every moment.
library;

enum AssistantPhase {
  idle,
  listening,
  transcribing,
  thinking,
  searching,
  findingContact,
  preparingMessage,
  generatingVoice,
  waitingForConfirmation,
  dialing,
  ringing,
  inCall,
  speaking,
  completed,
  error;

  static AssistantPhase fromWire(String s) => switch (s) {
        'listening' => AssistantPhase.listening,
        'transcribing' => AssistantPhase.transcribing,
        'thinking' => AssistantPhase.thinking,
        'searching' => AssistantPhase.searching,
        // The backend enters this while a tool runs (ordering, booking,
        // looking a place up). Unmapped it fell through to idle, so the
        // status pill read "Ready" while Hari was mid-errand.
        'using_tool' => AssistantPhase.searching,
        'finding_contact' => AssistantPhase.findingContact,
        'preparing_message' => AssistantPhase.preparingMessage,
        'generating_voice' => AssistantPhase.generatingVoice,
        'waiting_for_confirmation' => AssistantPhase.waitingForConfirmation,
        'dialing' => AssistantPhase.dialing,
        'ringing' => AssistantPhase.ringing,
        'in_call' => AssistantPhase.inCall,
        'speaking' => AssistantPhase.speaking,
        'completed' => AssistantPhase.completed,
        'error' => AssistantPhase.error,
        _ => AssistantPhase.idle,
      };

  /// Short human label for the status pill.
  ///
  /// The user sees what the ASSISTANT is doing, not what the voice
  /// pipeline is doing. Internal stages — transcribing, generating voice,
  /// preparing a message — all read as "Thinking…", because "Transcribing…"
  /// is a debug state, not something a person waiting for an answer needs
  /// to know (§6). The phases themselves are unchanged; only their
  /// user-facing wording is.
  String get label => switch (this) {
        AssistantPhase.idle => 'Ready',
        AssistantPhase.listening => 'Listening…',
        AssistantPhase.transcribing => 'Thinking…',
        AssistantPhase.thinking => 'Thinking…',
        AssistantPhase.searching => 'Searching…',
        AssistantPhase.findingContact => 'Finding contact…',
        AssistantPhase.preparingMessage => 'Thinking…',
        AssistantPhase.generatingVoice => 'Thinking…',
        AssistantPhase.waitingForConfirmation => 'Waiting for you',
        AssistantPhase.dialing => 'Dialing…',
        AssistantPhase.ringing => 'Ringing…',
        AssistantPhase.inCall => 'On the call',
        AssistantPhase.speaking => 'Speaking…',
        AssistantPhase.completed => 'Done',
        AssistantPhase.error => 'Something went wrong',
      };

  /// Whether a running action can be cancelled from the UI.
  bool get cancellable => switch (this) {
        AssistantPhase.thinking ||
        AssistantPhase.searching ||
        AssistantPhase.findingContact ||
        AssistantPhase.preparingMessage ||
        AssistantPhase.generatingVoice ||
        AssistantPhase.waitingForConfirmation =>
          true,
        _ => false,
      };

  bool get busy =>
      this != AssistantPhase.idle &&
      this != AssistantPhase.completed &&
      this != AssistantPhase.error;
}

// ---------------- transcript ----------------

enum TranscriptRole { user, assistant, system }

class TranscriptEntry {
  final TranscriptRole role;
  final String text;
  final DateTime at;
  TranscriptEntry(this.role, this.text) : at = DateTime.now();
}

// ---------------- tools / cards ----------------

class SearchResult {
  final String title;
  final String url;
  final String snippet;
  final String source;
  const SearchResult({
    required this.title,
    required this.url,
    required this.snippet,
    required this.source,
  });

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
        title: j['title'] as String? ?? '',
        url: j['url'] as String? ?? '',
        snippet: j['snippet'] as String? ?? '',
        source: j['source'] as String? ?? '',
      );
}

class ContactMatch {
  final String id;
  final String name;
  final String phone;
  const ContactMatch({required this.id, required this.name, required this.phone});

  factory ContactMatch.fromJson(Map<String, dynamic> j) => ContactMatch(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone};
}

/// A pending "should I do this?" from the assistant.
class PendingConfirmation {
  final String action; // "place_call" | "generic"
  final String? question;
  final ContactMatch? contact;
  final String? message;
  final String? spokenPreview;
  const PendingConfirmation({
    required this.action,
    this.question,
    this.contact,
    this.message,
    this.spokenPreview,
  });
}

class CallStatusInfo {
  final String status; // dialing | ringing | in_call | completed | failed | no_answer
  final String contactName;
  const CallStatusInfo({required this.status, required this.contactName});

  String get label => switch (status) {
        'dialing' => 'Dialing',
        'ringing' => 'Ringing',
        'in_call' => 'In call',
        // The backend's agent-call engine reports these two while Hari is
        // actually speaking to the business. Without them the card showed
        // the raw state string ("in_progress") to the user.
        'in_progress' => 'Speaking with them',
        'summarizing' => 'Getting the answer',
        'completed' => 'Call completed',
        'ended' => 'Call ended',
        'timeout' => 'Call timed out',
        'cancelled' => 'Cancelled',
        'failed' => 'Call failed',
        'no_answer' => 'No answer',
        _ => status,
      };

  bool get done =>
      status == 'completed' ||
      status == 'failed' ||
      status == 'no_answer' ||
      status == 'ended' ||
      status == 'timeout' ||
      status == 'cancelled';
}

/// A tool run shown as a small "what I'm doing" chip/card.
class ToolActivity {
  final String tool;
  final String label;
  bool completed;
  ToolActivity({required this.tool, required this.label, this.completed = false});
}
