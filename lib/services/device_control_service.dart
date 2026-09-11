import 'package:flutter/services.dart';

/// On-device controls (flashlight, volume, media, battery, settings) —
/// the phone half of the assistant's phone_control tool. Every call
/// returns honest success/failure; nothing is assumed done.
class DeviceControlService {
  DeviceControlService._();
  static final DeviceControlService instance = DeviceControlService._();

  static const _ch = MethodChannel('hari/device');

  Future<bool> torch(bool on) async =>
      await _call<bool>('torch', {'on': on}) ?? false;

  Future<bool> volume(String mode, {int value = 0}) async =>
      await _call<bool>('volume', {'mode': mode, 'value': value}) ?? false;

  Future<bool> media(String key) async =>
      await _call<bool>('media', {'key': key}) ?? false;

  /// Battery percent, or null when unreadable.
  Future<int?> battery() async {
    final v = await _call<int>('battery', {});
    return (v == null || v < 0) ? null : v;
  }

  Future<bool> openPanel(String panel) async =>
      await _call<bool>('openPanel', {'panel': panel}) ?? false;

  Future<T?> _call<T>(String method, Map<String, Object?> args) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }
}
