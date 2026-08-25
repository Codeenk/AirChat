import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

/// Small helper for Android version gates (old-device compatibility).
class DeviceInfoHelper {
  DeviceInfoHelper._();

  /// Returns the Android SDK int (e.g. "33"), or "33" on non-Android.
  static Future<String> androidSdkInt() async {
    if (!Platform.isAndroid) return '33';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt.toString();
    } catch (_) {
      return '33';
    }
  }

  /// Returns the device manufacturer (e.g. "realme", "Xiaomi"), or "" on
  /// non-Android.
  static Future<String> manufacturer() async {
    if (!Platform.isAndroid) return '';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.manufacturer;
    } catch (_) {
      return '';
    }
  }
}
