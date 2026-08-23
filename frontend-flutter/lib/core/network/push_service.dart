import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'notification_service.dart';
import '../network/api_client.dart';
import '../crypto/key_store.dart';
import '../database/daos/contact_dao.dart';

class PushService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final ApiClient _apiClient;

  PushService(this._apiClient);

  Future<void> initialize() async {
    // Visible notifications are now expected — request full permissions.
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) return;

    await NotificationService.instance.initialize();
    await NotificationService.instance.requestPermissions();

    final token = await _messaging.getToken();
    if (token != null) {
      await _apiClient.sendFcmToken(token);
    }

    _messaging.onTokenRefresh.listen((newToken) {
      _apiClient.sendFcmToken(newToken);
    });

    // Foreground FCM messages (rare — WS carries live traffic). Show a
    // notification so nothing is silently dropped.
    FirebaseMessaging.onMessage.listen((message) {
      _handleWake(message);
    });

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }
}

/// Resolves a friendly sender name for wake notifications. Falls back to the
/// uid tail when the contact isn't stored locally and directory lookup fails
/// (e.g. offline).
Future<String> _resolveSenderName(String? senderUid) async {
  if (senderUid == null || senderUid.isEmpty) return 'AirChat';
  try {
    final contact = await ContactDao().getContactByUid(senderUid);
    if (contact != null && contact.username.isNotEmpty) return contact.username;
    final info = await const ApiClient().lookupIdentity(uid: senderUid);
    final username = info?['username'] as String?;
    if (username != null && username.isNotEmpty) return username;
  } catch (_) {}
  return 'peer_${senderUid.length > 8 ? senderUid.substring(senderUid.length - 8) : senderUid}';
}

Future<void> _showWakeNotification(RemoteMessage message) async {
  final data = message.data;
  if (data['type'] != 'wake') return;
  final name = await _resolveSenderName(data['senderUid'] as String?);
  await NotificationService.instance.showMessageNotification(
    title: name,
    body: 'You have a new message',
  );
}

void _handleWake(RemoteMessage message) {
  // Foreground: MessageRouter surfaces messages in-app already.
  if (NotificationService.isAppForeground) return;
  _showWakeNotification(message);
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Fresh background isolate — everything must be initialized from scratch.
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
  await KeyStore.getOrCreateDatabaseMasterKey();
  await NotificationService.instance.initialize();
  await _showWakeNotification(message);
}
