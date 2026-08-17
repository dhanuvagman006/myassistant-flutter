const fs = require('fs');
const file = '/home/sudorabbit/Hariraj_project/myassistant-flutter/lib/features/assistant/state/assistant_engine.dart';
let content = fs.readFileSync(file, 'utf-8');

const startIndex = content.indexOf('Future<void> pressMic({bool auto = false}) async {');
const endIndex = content.indexOf('  Future<void> cancelAction() async {');

if (startIndex > -1 && endIndex > -1) {
  const newPressMic = `Future<void> pressMic({bool auto = false}) async {
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
  fs.writeFileSync(file, content);
  console.log("Fixed pressMic");
} else {
  console.log("Could not find boundaries");
}
