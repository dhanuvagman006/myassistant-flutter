import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:myassistant/services/api_service.dart';

class PushService {
  PushService._();
  static final PushService instance = PushService._();

  bool _initialized = false;

  /// Call this in main.dart after Firebase.initializeApp()
  Future<void> init() async {
    if (_initialized) return;
    try {
      // Request permission for push notifications (vital on iOS)
      NotificationSettings settings = await FirebaseMessaging.instance.requestPermission();
      
      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        String? token = await FirebaseMessaging.instance.getToken();
        if (token != null) {
          // Send the token to the backend so Hari knows where to route messages
          await ApiService.sendJson('/profile/details', method: 'PUT', body: {'fcm_token': token});
        }
        
        // Listen for token refreshes
        FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
          ApiService.sendJson('/profile/details', method: 'PUT', body: {'fcm_token': newToken});
        });

        _initialized = true;
      }
    } catch (e) {
      print('Firebase Push Initialization failed. Ensure flutterfire configure was run: $e');
    }
  }
}
