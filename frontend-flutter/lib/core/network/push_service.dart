import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import 'notification_service.dart';
import '../crash/crash_reporter.dart';
import '../network/api_client.dart';
import '../crypto/key_store.dart';
import '../crypto/sodium_engine.dart';
import '../database/app_database.dart';
import '../database/daos/chat_dao.dart';
import '../database/daos/contact_dao.dart';
import '../database/daos/message_dao.dart';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:native_bridge/native_bridge.dart';

import '../../models/chat_thread.dart';
import '../../models/message_payload.dart';

String buildChatId(String a, String b) {
  final ids = [a, b]..sort();
  return ids.join('_');
}

class PushService {
  static const _storage = FlutterSecureStorage();
  static const String _keyBatteryOptimizationPrompted =
      'airchat_battery_opt_asked';

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

    // IMPORTANT: do NOT early-return when denied — the FCM token must be
    // registered regardless, otherwise the device silently receives zero
    // pushes forever (even if the user grants permission later, until the
    // next app restart). Permission is re-requested on every launch, so a
    // later grant starts working immediately.
    await NotificationService.instance.initialize();
    if (settings.authorizationStatus != AuthorizationStatus.denied) {
      await NotificationService.instance.requestPermissions();
    }
    await _ensureBatteryOptimizationExempt();

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

  /// THE fix for "notifications don't arrive when the app is killed":
  /// OEM battery managers (Xiaomi/Oppo/Vivo/Samsung deep sleep) block FCM
  /// from spawning our background isolate for data-only pushes. Exempting
  /// the app from battery optimization is the standard, user-approved fix.
  /// The system dialog is shown at most once (flag in secure storage).
  Future<void> _ensureBatteryOptimizationExempt() async {
    try {
      final asked = await _storage.read(key: _keyBatteryOptimizationPrompted);
      if (asked == '1') return;
      final status = await ph.Permission.ignoreBatteryOptimizations.status;
      if (!status.isGranted) {
        await ph.Permission.ignoreBatteryOptimizations.request();
      }
      await _storage.write(key: _keyBatteryOptimizationPrompted, value: '1');
    } catch (_) {
      // Unsupported platform — non-fatal.
    }
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

Future<void> _showWakeNotification(
  RemoteMessage message, {
  String? bodyOverride,
}) async {
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
  debugPrint('[AirChat][bg] handler entered data=${message.data}');
  try {
    // Fresh background isolate — everything must be initialized from scratch.
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    await NotificationService.instance.initialize();

    // Notification health self-test: record receipt so the Health screen
    // can show "verified working".
    if (message.data['senderUid'] == 'self_test') {
      await _handleSelfTest();
      return;
    }

    // 24h cache expired: the sender's message was destroyed undelivered.
    // Mark it failed locally + tell the sender honestly.
    if (message.data['type'] == 'delivery_failed') {
      await _handleDeliveryFailed(message.data);
      return;
    }

    // Signal/Delta-Chat trick: promote to a dataSync foreground service for
    // ~12s — guarantees network access on OEM-restricted phones while the
    // isolate fetches the queued message.
    await NativeBridge.startWakeGuard();

    // Data-only wake: try to fetch + decrypt the queued message over the WS
    // (time-boxed) so the notification shows the REAL text. Falls back
    // to the generic body on timeout/offline.
    String? realText;
    try {
      realText = await _fetchQueuedMessage(message);
    } catch (e) {
      debugPrint('[AirChat][bg] enrich failed: $e');
    }
    await _showWakeNotification(message, bodyOverride: realText);
    debugPrint(
      '[AirChat][bg] wake notification shown (real=${realText != null})',
    );
  } catch (e, st) {
    debugPrint('[AirChat][bg] handler failed: $e\n$st');
    CrashReporter.recordError(error: e, stackTrace: st, source: 'fcm-bg');
  }
}

/// Records a successful push round-trip for the Notification Health screen.
Future<void> _handleSelfTest() async {
  try {
    const storage = FlutterSecureStorage();
    await storage.write(
      key: 'airchat_last_push_verified',
      value: DateTime.now().millisecondsSinceEpoch.toString(),
    );
    debugPrint('[AirChat][bg] self-test push received');
  } catch (_) {}
}

/// Marks the sender's expired messages as 'expired' in the local DB and
/// surfaces an honest "not delivered" notification.
Future<void> _handleDeliveryFailed(Map<String, dynamic> data) async {
  try {
    final packetIdsRaw = data['packetIds'] as String?;
    if (packetIdsRaw == null) return;
    final packetIds = (jsonDecode(packetIdsRaw) as List<dynamic>)
        .whereType<String>()
        .toList();
    if (packetIds.isEmpty) return;

    await AppDatabase.instance;
    for (final id in packetIds) {
      await MessageDao().updateMessageStatus(id, 'expired');
    }

    final recipientUid = data['recipientUid'] as String?;
    final contact = recipientUid != null
        ? await ContactDao().getContactByUid(recipientUid)
        : null;
    final name = contact?.username ?? 'your contact';
    await NotificationService.instance.showMessageNotification(
      title: 'Message not delivered',
      body:
          'Your message to $name expired after 24h — they were offline. Open AirChat to retry.',
      senderUid: recipientUid,
    );
    debugPrint('[AirChat][bg] marked ${packetIds.length} messages expired');
  } catch (e, st) {
    debugPrint('[AirChat][bg] delivery_failed handling failed: $e');
    CrashReporter.recordError(
      error: e,
      stackTrace: st,
      source: 'delivery-failed',
    );
  }
}

/// Connects the tunnel briefly to pull the queued encrypted message from the
/// relay, decrypts it, persists it locally, and returns the preview text.
/// Uses a raw pure-Dart WebSocket (no plugins — guaranteed to work in a
/// background isolate where plugin registration is unavailable).
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
  Timer(const Duration(seconds: 15), () {
    if (!completer.isCompleted) completer.complete(null);
  });

  debugPrint('[AirChat][bg] fetch: raw WS connect as $myUid');
  final channel = WebSocketChannel.connect(
    Uri.parse(
      'wss://airchat-relay.malandkar-sarvesh1.workers.dev/tunnel?uid=$myUid',
    ),
  );
  channel.ready
      .then((_) {
        debugPrint('[AirChat][bg] WS READY');
      })
      .catchError((e) {
        debugPrint('[AirChat][bg] WS READY FAILED: $e');
      });
  late final StreamSubscription<dynamic> sub;
  sub = channel.stream.listen(
    (raw) {
      final rawStr = raw is String ? raw : utf8.decode(raw as List<int>);
      try {
        final msg = jsonDecode(rawStr) as Map<String, dynamic>;
        if (msg['type'] != 'direct_message') return;
        if (msg['senderUid'] != senderUid) return;

        final cryptoPayload = CryptoPayload.decode(msg['payload'] as String);
        Future(() async {
          final decrypted = await engine.decryptMessage(
            payload: cryptoPayload,
            recipientKeyPair: keyPair,
          );
          final decoded = jsonDecode(decrypted);
          final text = (decoded['text'] as String?) ?? '';
          final type = (decoded['type'] as String?) ?? 'text';
          final packetId = msg['packetId'] as String?;
          final timestamp =
              (msg['timestamp'] as int?) ??
              DateTime.now().millisecondsSinceEpoch;

          final chatId = buildChatId(myUid, senderUid);

          // Persist so the app shows it on next open (idempotent by packetId).
          await MessageDao().insertMessage(
            ChatMessage(
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
            ),
          );
          await ChatDao().updatePreviewPreservingUnread(
            ChatThread(
              id: chatId,
              contactUid: senderUid,
              lastMessage: text.isEmpty ? '\u{1F4CE} $type' : text,
              lastMessageTime: timestamp,
            ),
          );
          await ChatDao().incrementUnread(chatId);
          // Ack so the relay deletes the queued copy.
          channel.sink.add(
            jsonEncode({
              'action': 'ack',
              if (packetId != null) 'packetId': packetId,
              'senderUid': senderUid,
            }),
          );
          if (!completer.isCompleted) {
            completer.complete(text.isEmpty ? '\u{1F4CE} $type' : text);
          }
        }).catchError((e) {
          debugPrint('[AirChat][bg] decrypt/persist failed: $e');
        });
      } catch (e) {
        debugPrint('[AirChat][bg] ws msg processing failed: $e');
      }
    },
    onError: (e) {
      if (!completer.isCompleted) completer.complete(null);
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(null);
    },
  );

  final result = await completer.future;
  await sub.cancel();
  try {
    await channel.sink.close();
  } catch (_) {}
  debugPrint(
    '[AirChat][bg] fetch result: ${result != null ? 'got text' : 'timeout'}',
  );
  return result;
}
