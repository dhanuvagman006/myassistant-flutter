import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// TRUE automatic SMS — the delivery ladder's second rung. When the
/// recipient isn't an app user, the assistant's message goes out as a
/// plain text with zero taps: SmsManager on the platform side, the
/// runtime SEND_SMS permission asked here the first time.
class SmsService {
  SmsService._();
  static final SmsService instance = SmsService._();

  static const _channel = MethodChannel('hari/sms');

  /// Sends [body] to [to]. Returns null on success, or a short
  /// plain-language reason on failure (permission refused, no SIM…).
  Future<String?> send(String to, String body) async {
    final number = to.trim();
    if (number.isEmpty || body.trim().isEmpty) return 'nothing to send';
    try {
      var status = await Permission.sms.status;
      if (!status.isGranted) {
        status = await Permission.sms.request();
      }
      if (!status.isGranted) {
        return 'SMS permission is not granted — allow it in Settings';
      }
      final ok = await _channel.invokeMethod<bool>(
          'sendSms', {'to': number, 'body': body});
      return ok == true ? null : 'the phone could not send the SMS';
    } catch (_) {
      return 'the phone could not send the SMS';
    }
  }
}
