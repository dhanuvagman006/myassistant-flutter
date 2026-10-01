import 'dart:async';

import '../../core/log.dart';
import '../../services/avatar_message_service.dart';
import '../meeting_prep/meeting_prep.dart';
import '../meeting_prep/meeting_prep_sheet.dart';
import 'brief_player.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THE VOICE HALF (2026-09-30): what the server's play_daily_brief and
///  prepare_meeting tools hand the phone.
///
///    play_brief         { part }  — the spoken day starts (it fetches its
///                                   own words, with the missed calls)
///    open_meeting_prep  { prep }  — the Meeting Prep sheet opens with it
///
///  Both return at once: the brain is waiting to tell the model how the
///  action went, and a minute of speech must not hold its turn open.
/// ─────────────────────────────────────────────────────────────────────────
abstract final class BriefingDirectives {
  static const types = {'play_brief', 'open_meeting_prep'};

  static Future<void> handle(Map<String, dynamic> e) async {
    switch (e['type']) {
      case 'play_brief':
        unawaited(BriefPlayer.instance.play(
          overlay: AvatarMessageService.navigatorKey.currentState?.overlay,
          fromVoice: true,
        ));
      case 'open_meeting_prep':
        final raw = e['prep'];
        final ctx = AvatarMessageService.navigatorKey.currentContext;
        if (ctx == null || !ctx.mounted) {
          AppLog.add('prep', 'no screen to show the meeting prep on');
          return;
        }
        unawaited(showMeetingPrep(
          ctx,
          prep: raw is Map<String, dynamic> ? MeetingPrep.fromJson(raw) : null,
        ));
    }
  }
}
