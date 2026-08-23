import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// No local notifications on web (no plugin implementation) — calls become
  /// harmless no-ops.
  bool get _supported => !kIsWeb;

  /// Tracks whether the Flutter UI is currently visible. The MessageRouter
  /// only shows local notifications when this is false.
  static bool isAppForeground = false;

  int _notificationId = 1000;

  Future<void> initialize() async {
    if (_initialized || !_supported) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(settings: const InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    ));
    _initialized = true;
  }

  Future<bool> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission();
      return granted ?? false;
    }
    return true;
  }

  Future<void> showMessageNotification({
    required String title,
    required String body,
  }) async {
    if (!_initialized) await initialize();
    if (!_supported) return;

    const androidDetails = AndroidNotificationDetails(
      'airchat_messages',
      'Messages',
      channelDescription: 'New end-to-end encrypted messages',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      showWhen: true,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      id: _notificationId++,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }
}
