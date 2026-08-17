const fs = require('fs');
const file = '/home/sudorabbit/Hariraj_project/myassistant-flutter/lib/features/assistant/state/assistant_engine.dart';
let content = fs.readFileSync(file, 'utf-8');

// 1. Rewrite pressMic completely
const startIndex = content.indexOf('  Future<void> pressMic({bool auto = false}) async {');
const endIndex = content.indexOf('  Future<void> cancelAction() async {');
if (startIndex > -1 && endIndex > -1) {
  const newPressMic = `  Future<void> pressMic({bool auto = false}) async {
    _conversationEnded = false;
    _setLocalError(null);
    _silentTurns = 0;
    _failedTurns = 0;
    
    if (liveActive) {
      await stopLive();
      return;
    }

    if (phase == AssistantPhase.listening || phase == AssistantPhase.speaking || _ttsActive || (phase.busy && phase != AssistantPhase.completed)) {
      final wasListening = phase == AssistantPhase.listening;
      await cancelAction();
      if (wasListening) {
        await _voice.cancelCapture();
      }
      return;
    }

    if (_bargeMonitorOn) {
      _bargeMonitorOn = false;
      _bargedIn = false;
      await _voice.stopBargeInMonitor();
    }
    await _voice.stopSpeaking();

    if (!await _voice.canRecord()) {
      _setLocalError('Microphone permission is needed. Enable it in Settings.');
      return;
    }

    HapticFeedback.mediumImpact();
    
    final ok = await _startLive();
    if (!ok) {
      _setLocalError("Could not connect to Live Voice.");
    }
  }

`;
  content = content.substring(0, startIndex) + newPressMic + content.substring(endIndex);
}

// 2. Add _liveSvc.onAppEvent
content = content.replace(
  /_liveSvc\.onHariText = \(t\) => AppLog\.add\('live', 'hari: \$t'\);\s+_liveSvc\.onTurnComplete = \(\) \{\};/g,
  `_liveSvc.onHariText = (t) => AppLog.add('live', 'hari: $t');
    _liveSvc.onAppEvent = (evt) => _onEvent(evt);
    _liveSvc.onTurnComplete = () {};`
);

// 3. Fix _liveSvc.onError
content = content.replace(
  /_liveSvc\.onError = \(msg\) \{\s+\/\/ NO visible error\. Log it, mark live unavailable for this run, and\s+\/\/ silently fall back to the classic path by rejecting the start promise\.\s+AppLog\.add\('live', 'error: \$msg'\);\s+_liveUnavailable = true;\s+if \(_liveStartResult\?\.isCompleted == false\) \{\s+_liveStartResult!\.complete\(false\);\s+\}\s+stopLive\(\);\s+\};/g,
  `_liveSvc.onError = (msg) {
      AppLog.add('live', 'error: $msg');
      if (_liveStartResult?.isCompleted == false) {
        _liveStartResult!.complete(false);
      }
      stopLive();
      _setLocalError(msg);
    };`
);

fs.writeFileSync(file, content);
console.log("Rewrote assistant_engine.dart");
