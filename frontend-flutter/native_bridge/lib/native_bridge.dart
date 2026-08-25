import 'package:flutter/services.dart';

/// Dart side of the native bridge. Safe to call from any isolate — the
/// plugin registers on every Flutter engine (main + FCM background).
class NativeBridge {
  static const _channel = MethodChannel('airchat/native');

  static Future<void> _invoke(String action) async {
    try {
      await _channel.invokeMethod('call', {'action': action});
    } on MissingPluginException {
      // Non-Android or engine without the plugin — non-fatal.
    } catch (_) {
      // OEM may block background FGS start — non-fatal by design.
    }
  }

  /// Promotes the app to a dataSync foreground service for ~12s so the
  /// FCM-woken background isolate is guaranteed network access.
  static Future<void> startWakeGuard() => _invoke('startWakeGuard');

  /// Starts the persistent Wire Keeper (remoteMessaging FGS).
  static Future<void> startWireKeeper() => _invoke('startWireKeeper');

  /// Stops the Wire Keeper.
  static Future<void> stopWireKeeper() => _invoke('stopWireKeeper');
}
