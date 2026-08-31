import 'package:geolocator/geolocator.dart';

import 'api_service.dart';

/// Keeps [ApiService.geoLat]/[geoLng] filled with the last known GPS fix
/// so every backend call carries the user's real location — weather,
/// nearby hotels/restaurants, cab pickups, "near me" anything.
///
/// Low accuracy on purpose: city-block precision is plenty for these
/// answers, costs almost no battery, and resolves fast. All failures are
/// silent — a missing fix just means the assistant asks for the city.
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  DateTime? _lastFix;

  /// Refreshes the cached coordinates. Cheap to call often — it no-ops
  /// within 10 minutes of a successful fix and uses the OS's last known
  /// position before ever powering the GPS.
  Future<void> refresh() async {
    final last = _lastFix;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 10)) {
      return;
    }
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      Position? pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.low),
      ).timeout(const Duration(seconds: 10));
      ApiService.geoLat = pos.latitude;
      ApiService.geoLng = pos.longitude;
      _lastFix = DateTime.now();
    } catch (_) {
      // No fix, no drama — backend tools fall back to asking for a city.
    }
  }
}
