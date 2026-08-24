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
}
