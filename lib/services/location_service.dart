import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';

/// Keeps [ApiService.geoLat]/[geoLng] filled with the last known GPS fix
/// so every backend call carries the user's real location — weather,
/// nearby hotels/restaurants, cab pickups, "near me" anything.
///
/// Low accuracy on purpose: city-block precision is plenty for these
/// answers, costs almost no battery, and resolves fast. All failures are
/// silent — a missing fix just means the assistant asks for the city.
///
/// Owner, 2026-09-24: "my assistant should be aware of user location when
/// he makes any requests". So the fix is kept CURRENT, not just present:
/// the engine refreshes it every 5 minutes while the app is on screen and
/// right before a voice session starts, and the live session is told when
/// it moves (LiveService.maybeSendLocation).
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  DateTime? _lastFix;
  Future<void>? _inFlight;

  /// Metres, of the last fix (null when unknown).
  double? accuracy;

  /// A fix this young is reused as it is: the 5-minute tick, the resume
  /// and the live start can all land within the same minute.
  static const _fresh = Duration(seconds: 60);

  /// How old the phone's own last-known position may be before a real
  /// (network-accuracy) fix is taken instead.
  static const _maxAge = Duration(minutes: 5);

  /// Refreshes the cached coordinates. Cheap to call often — it reuses a
  /// fix under a minute old, joins a refresh already running, and uses the
  /// OS's last known position (when it is recent) before ever powering the
  /// GPS.
  Future<void> refresh() {
    final running = _inFlight;
    if (running != null) return running;
    final last = _lastFix;
    if (last != null && DateTime.now().difference(last) < _fresh) {
      return Future.value();
    }
    final f = _refresh().whenComplete(() => _inFlight = null);
    _inFlight = f;
    return f;
  }

  Future<void> _refresh() async {
    try {
      // Check, never ask: this runs on every launch and resume, and asking
      // here re-prompted anyone who had declined. The Permissions screen
      // asks, and so does [askOnce] — once — the first time a request
      // needs it; without it, "near me" just has no location.
      if (!await granted()) return;
      // A last-known fix is only a shortcut when it is RECENT. Taking any
      // cached position unconditionally meant a fix from yesterday — or
      // another city — was used forever, which is exactly "best near me
      // fails": the agent knew a location, just not the user's.
      Position? pos = await Geolocator.getLastKnownPosition();
      final fixAge = pos == null
          ? null
          : DateTime.now().difference(pos.timestamp);
      if (pos == null || fixAge == null || fixAge > _maxAge) {
        pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.medium),
        ).timeout(const Duration(seconds: 10));
      }
      ApiService.geoLat = pos.latitude;
      ApiService.geoLng = pos.longitude;
      accuracy = pos.accuracy;
      _lastFix = DateTime.now();
    } catch (_) {
      // No fix, no drama — backend tools fall back to asking for a city.
    }
  }

  /// Is location allowed for the app? Never asks.
  Future<bool> granted() async {
    try {
      final perm = await Geolocator.checkPermission();
      return perm == LocationPermission.whileInUse ||
          perm == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  static const _kAsked = 'location_permission_asked';

  /// THE ONE ASK. The first time a request needs the owner's location and
  /// it is not allowed, this shows [explain]'s one line and Android's
  /// dialog — and remembers it asked, so it never asks again (the
  /// Permissions screen and the phone's settings remain). True when
  /// location is on afterwards.
  Future<bool> askOnce({void Function(String line)? explain}) async {
    if (await granted()) return true;
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(_kAsked) == true) return false;
      await p.setBool(_kAsked, true);
    } catch (_) {
      return false; // cannot remember asking — so do not ask
    }
    try {
      // Refused for good earlier: Android shows no dialog any more, so the
      // one line says where the switch is instead.
      if (await Geolocator.checkPermission() ==
          LocationPermission.deniedForever) {
        explain?.call('Location is off for the assistant — turn it on in '
            'the phone settings for "near me" answers.');
        return false;
      }
      explain?.call('To answer "near me" questions, allow your location.');
      final r = await Geolocator.requestPermission();
      final ok = r == LocationPermission.whileInUse ||
          r == LocationPermission.always;
      if (ok) {
        _lastFix = null;
        await refresh();
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Words that only make sense with the owner's position ("near me",
  /// "nearest", "where am I", "directions to", "book a cab"). Plain
  /// "weather in Delhi" is not one of them.
  static final RegExp _needsHere = RegExp(
    r"\b(near ?me|nearby|near here|around (?:me|here)|close to me|closest|"
    r"nearest|where am i|my (?:current )?location|current location|"
    r"weather here|from here|directions? to|navigate to|take me to|"
    r"how far|book (?:a |an )?(?:cab|taxi|ride|auto))\b",
    caseSensitive: false,
  );

  static bool needsHere(String text) => _needsHere.hasMatch(text);

  /// Server tools whose start means "this request needs the owner's
  /// position" (the engine then asks once, see [askOnce]).
  ///
  /// Only tools the server still OFFERS with location off belong here.
  /// find_places_nearby, get_current_location and start_navigation carry
  /// requiresPermission "location": with location denied the server hides
  /// them from the model, so their start can never arrive while there is
  /// anything to ask — and with it allowed there is nothing to ask. Those
  /// requests are caught by their words instead ([needsHere]).
  static const locationTools = {
    'book_ride',
  };
}
