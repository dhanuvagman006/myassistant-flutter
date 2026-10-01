import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/log.dart';
import '../../services/avatar_message_service.dart';
import 'studio_controller.dart';
import 'studio_models.dart';
import 'studio_screen.dart';

/// Opens the Poster Studio from anywhere (the Hub, the photo-card screen,
/// the assistant's `open_poster_studio`), never stacking a second copy.
abstract final class PosterStudioNav {
  static bool show({String? request}) {
    if (PosterStudioScreen.showing > 0) return true;
    final nav = AvatarMessageService.navigatorKey.currentState;
    if (nav == null) return false;
    unawaited(nav.push(route(request: request)));
    return true;
  }

  /// The studio as a page that rises from below, for callers with their
  /// own navigator.
  static Route<void> route({String? request, PosterStudioController? controller}) =>
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => PosterStudioScreen(controller: controller, request: request),
      );

  static Future<void> open(BuildContext context, {String? request}) =>
      Navigator.of(context).push(route(request: request));
}

/// Where the assistant's directive shows the studio: the app's navigator,
/// a fake in tests.
abstract class PosterStudioHost {
  /// Brings the studio up (or keeps it up). False when there is nowhere
  /// to show it.
  bool showStudio();
}

class NavStudioHost implements PosterStudioHost {
  const NavStudioHost();
  @override
  bool showStudio() => PosterStudioNav.show();
}

/// Handles `open_poster_studio` (create_event_poster, build 135+): the
/// design's words fill the studio at once and it opens; the background
/// arrives by itself (or is polled for) while he looks.
class PosterStudioActions {
  PosterStudioActions({PosterStudioHost? host, PosterStudioController? controller})
      : host = host ?? const NavStudioHost(),
        c = controller ?? PosterStudioController.instance;

  static const type = 'open_poster_studio';

  final PosterStudioHost host;
  final PosterStudioController c;

  Future<void> handle(Map<String, dynamic> e) async {
    if (e['type'] != type) return;
    try {
      final opening = c.openDirective(StudioDirective.fromJson(e));
      if (!host.showStudio()) AppLog.add('poster', 'studio: nowhere to show it');
      await opening;
    } catch (err) {
      AppLog.add('poster', 'open_poster_studio failed: $err');
    }
  }
}

