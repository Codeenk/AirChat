import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/colors.dart';

class BatteryOptHelper {
  static const _channel = MethodChannel('airchat/native_battery');
  static const _storage = FlutterSecureStorage();
  static const _seenKey = 'airchat_battery_prompt_shown';

  /// True if already exempt from battery optimizations (Doze/App Standby).
  /// Covers Android 6 (API 23) through Android 15 (API 35):
  /// - API <23: always true (no Doze)
  /// - API 23+: PowerManager.isIgnoringBatteryOptimizations
  /// Wrapped in try/catch for OEMs that throw ServiceSpecificException (code 7) or return stale values.
  static Future<bool> isExempt() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      // Try native channel first (direct PowerManager check, most reliable)
      final result = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      if (result != null) return result;
    } catch (_) {}
    try {
      final status = await ph.Permission.ignoreBatteryOptimizations.status;
      return status.isGranted;
    } catch (_) {
      return true;
    }
  }

  /// Requests exemption seamlessly — direct dialog on most devices.
  /// Falls back gracefully on OEMs where direct intent is not available.
  /// Returns true if now exempt, false otherwise.
  static Future<bool> requestExemption() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final granted = await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      if (granted == true) return true;
      // If native handled it, re-check
      return await isExempt();
    } catch (_) {
      // Native channel not available — fallback to permission_handler
      try {
        final status = await ph.Permission.ignoreBatteryOptimizations.request();
        return status.isGranted;
      } catch (_) {
        return false;
      }
    }
  }

  /// Opens the system battery optimization settings (fallback, Play-compliant).
  static Future<void> openBatterySettings() async {
    try {
      await _channel.invokeMethod('openBatteryOptimizationSettings');
      return;
    } catch (_) {}
    try {
      await ph.openAppSettings();
    } catch (_) {}
  }

  /// Seamless first-launch flow: shows rationale dialog exactly once, then
  /// requests exemption if user allows. Mirrors notification permission UX.
  /// Call from HomeChatListScreen initState after first frame.
  static Future<void> maybePromptOnFirstLaunch(BuildContext context) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final seen = await _storage.read(key: _seenKey);
      if (seen == '1') return;
      final exempt = await isExempt();
      if (exempt) {
        await _storage.write(key: _seenKey, value: '1');
        return;
      }
      if (!context.mounted) return;
      final allow = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: AirColors.surface,
          title: const Text('Stay reachable',
              style: TextStyle(color: AirColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
          content: const Text(
            'AirChat needs to stay reachable in the background to deliver messages instantly — even when your phone is in battery saver or Doze mode.\n\n'
            'Allow battery unrestricted? You can change this anytime in Settings.',
            style: TextStyle(color: AirColors.textSecondary, fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now', style: TextStyle(color: AirColors.textSecondary)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AirColors.accent, foregroundColor: AirColors.background),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Allow'),
            ),
          ],
        ),
      );
      await _storage.write(key: _seenKey, value: '1');
      if (allow == true && context.mounted) {
        await requestExemption();
      }
    } catch (_) {}
  }
}
