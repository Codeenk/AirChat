import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'notification_service.dart';
import '../network/api_client.dart';
import '../crypto/key_store.dart';
import '../crypto/sodium_engine.dart';
import '../database/app_database.dart';
import '../database/daos/chat_dao.dart';
import '../database/daos/contact_dao.dart';
import '../database/daos/message_dao.dart';
import '../network/websocket_client.dart';
import '../../models/chat_thread.dart';
import '../../models/message_payload.dart';

String buildChatId(String a, String b) {
  final ids = [a, b]..sort();
  return ids.join('_');
}

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

Future<void> _showWakeNotification(RemoteMessage message,
    {String? bodyOverride}) async {
  final data = message.data;
  if (data['type'] != 'wake') return;

  final serverName = (data['senderName'] as String?)?.trim();
  final name = (serverName != null && serverName.isNotEmpty)
      ? serverName
      : await _resolveSenderName(data['senderUid'] as String?);
  await NotificationService.instance.showMessageNotification(
    title: name,
    body: bodyOverride ?? 'You have a new message',
    senderUid: data['senderUid'] as String?,
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
  await NotificationService.instance.initialize();

  if (message.notification != null) {
    // The OS already displayed the FCM notification ("You have a new
    // message"). Try to fetch the actual queued message over the WS and
    // REPLACE that generic notification with the real decrypted text.
    try {
      final real = await _fetchQueuedMessage(message);
      if (real != null) {
        await _showWakeNotification(message, bodyOverride: real);
        return;
      }
    } catch (_) {}
    // Nothing fetched (offline/timeout) — leave the OS notification as-is.
    return;
  }

  // Data-only fallback (legacy server): show immediately — no key
  // derivation, no DB, no network on this path.
  await _showWakeNotification(message);
}

/// Connects the tunnel briefly to pull the queued encrypted message from the
/// relay, decrypts it, persists it locally, and returns the preview text.
/// Time-boxed — returns null on any failure/timeout.
Future<String?> _fetchQueuedMessage(RemoteMessage message) async {
  final data = message.data;
  final senderUid = data['senderUid'] as String?;
  if (senderUid == null || senderUid.isEmpty) return null;

  final myUid = await KeyStore.getUid();
  final keyPair = await KeyStore.getKeyPair();
  if (myUid == null || myUid.isEmpty || keyPair == null) return null;

  await AppDatabase.instance;

  final engine = SodiumEngine();
  final completer = Completer<String?>();
  final ws = WebSocketTunnelClient(uid: myUid);
  StreamSubscription<Map<String, dynamic>>? sub;

  Timer(const Duration(seconds: 8), () {
    if (!completer.isCompleted) completer.complete(null);
  });

  sub = ws.messageStream.listen((msg) async {
    try {
      if (msg['type'] != 'direct_message') return;
      if (msg['senderUid'] != senderUid) return;

      final cryptoPayload = CryptoPayload.decode(msg['payload'] as String);
      final decrypted = await engine.decryptMessage(
        payload: cryptoPayload,
        recipientKeyPair: keyPair,
      );
      final decoded = jsonDecode(decrypted);
      final text = (decoded['text'] as String?) ?? '';
      final type = (decoded['type'] as String?) ?? 'text';
      final packetId = msg['packetId'] as String?;
      final timestamp =
          (msg['timestamp'] as int?) ?? DateTime.now().millisecondsSinceEpoch;

      final chatId = buildChatId(myUid, senderUid);

      // Persist so the app shows it on next open (idempotent by packetId).
      await MessageDao().insertMessage(ChatMessage(
        id: packetId ?? 'bg_$timestamp',
        chatId: chatId,
        senderUid: senderUid,
        recipientUid: myUid,
        text: text,
        type: type,
        timestamp: timestamp,
        isMe: false,
        status: 'delivered',
        replyToId: (decoded['replyTo']?['id'] as String?),
        replyText: (decoded['replyTo']?['text'] as String?) ?? '',
        replyType: (decoded['replyTo']?['type'] as String?) ?? 'text',
        replyIsMe: decoded['replyTo']?['isMe'] as bool?,
      ));
      await ChatDao().updatePreviewPreservingUnread(ChatThread(
        id: chatId,
        contactUid: senderUid,
        lastMessage: text.isEmpty ? '📎 $type' : text,
        lastMessageTime: timestamp,
      ));
      await ChatDao().incrementUnread(chatId);
      if (packetId != null) {
        ws.sendAck(packetId: packetId, senderUid: senderUid);
      }

      if (!completer.isCompleted) {
        completer.complete(text.isEmpty ? '📎 $type' : text);
      }
    } catch (_) {}
  });

  ws.connect();
  final result = await completer.future;
  await sub.cancel();
  ws.dispose();
  return result;
}
