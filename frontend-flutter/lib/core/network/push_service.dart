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
import '../crypto/relay_auth.dart';
import '../crypto/sodium_engine.dart';
import '../database/app_database.dart';
import '../database/daos/chat_dao.dart';
import '../database/daos/contact_dao.dart';
import '../database/daos/group_dao.dart';
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

    // Foreground FCM messages (rare — the live WS MessageRouter already
    // carries traffic in the foreground and raises a notification for every
    // conversation that is not the one currently open).
    FirebaseMessaging.onMessage.listen((message) {
      _handleWake(message);
    });
  }

  /// Helps keep pushes working on OEM devices that aggressively restrict
  /// background network. The system dialog is shown at most once (flag in
  /// secure storage).
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
  String? titleOverride,
  String? chatIdOverride,
}) async {
  final data = message.data;
  final wakeType = data['type'] as String?;

  // Group wake: resolve group + sender names locally (opaque push).
  if (wakeType == 'group_wake') {
    final groupId = data['groupId'] as String?;
    String groupName = 'Group';
    try {
      if (groupId != null && groupId.isNotEmpty) {
        final g = await GroupDao().getGroupById(groupId);
        if (g != null && g.name.isNotEmpty) groupName = g.name;
      }
    } catch (_) {}
    final name = await _resolveSenderName(data['senderUid'] as String?);
    await NotificationService.instance.showMessageNotification(
      title: titleOverride ?? '$groupName • $name',
      body: bodyOverride ?? 'New message in $groupName',
      senderUid: groupId,
    );
    return;
  }

  // Regular wake — sender name always resolved on-device.
  if (wakeType != 'wake') return;

  final senderUid = data['senderUid'] as String?;
  final name = await _resolveSenderName(senderUid);
  await NotificationService.instance.showMessageNotification(
    title: titleOverride ?? name,
    body: bodyOverride ?? 'You have a new message',
    // Key the notification on the real conversation: a legacy group message
    // stacks under its group, a 1:1 message under the sender.
    senderUid: chatIdOverride ?? senderUid,
  );
}

void _handleWake(RemoteMessage message) {
  // Foreground: MessageRouter surfaces messages in-app already.
  if (NotificationService.isAppForeground) return;
  final wakeType = message.data['type'] as String?;
  if (wakeType == 'group_wake') {
    _showGroupWakeNotification(message);
  } else {
    _showWakeNotification(message);
  }
}

/// Foreground group wake: show a notification immediately since the WS
/// MessageRouter may not handle it fast enough.
void _showGroupWakeNotification(RemoteMessage message) {
  _showWakeNotification(message);
}

/// Registers the FCM background handler. MUST be called before `runApp` so the
/// killed-state background isolate can spawn this handler. Safe to call on
/// every platform (non-Firebase platforms simply no-op).
void registerFirebaseBackgroundHandler() {
  try {
    FirebaseMessaging.onBackgroundMessage(airchatBackgroundHandler);
  } catch (e) {
    debugPrint('[AirChat] bg handler registration failed');
  }
}

@pragma('vm:entry-point')
Future<void> airchatBackgroundHandler(RemoteMessage message) async {
  // Do not dump the full push payload into logs. It may contain opaque
  // routing fields and should not be treated as free debug text.
  try {
    // Fresh background isolate — everything must be initialized from scratch.
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    await NotificationService.instance.initialize();

    final data = message.data;

    // Notification health self-test: record receipt so the Health screen
    // can show "verified working".
    if (data['senderUid'] == 'self_test') {
      await _handleSelfTest();
      return;
    }

    // 24h cache expired: the sender's message was destroyed undelivered.
    // Mark it failed locally + tell the sender honestly.
    if (data['type'] == 'delivery_failed') {
      await _handleDeliveryFailed(data);
      return;
    }

    // Signal/Delta-Chat trick: promote to a dataSync foreground service for
    // ~12s — guarantees network access on OEM-restricted phones while the
    // isolate fetches the queued message.
    await NativeBridge.startWakeGuard();

    // Route to the correct fetch path based on wake type.
    final wakeType = data['type'] as String?;
    String? realText;
    String? groupTitleOverride;
    String? chatIdOverride;
    try {
      if (wakeType == 'group_wake') {
        realText = await _fetchGroupMessage(message);
      } else {
        final fetched = await _fetchQueuedMessage(message);
        realText = fetched?.text;
        // Only label this with a group name when THIS payload is a group
        // message (legacy clients deliver group messages over the 1:1 wake
        // path). Never infer it from the sender's message history — a personal
        // message from someone who also happens to be in a group with you must
        // not be titled with that group's name.
        final fetchedGroupId = fetched?.groupId;
        if (fetchedGroupId != null && fetchedGroupId.isNotEmpty) {
          final group = await GroupDao().getGroupById(fetchedGroupId);
          final senderName = await _resolveSenderName(
            data['senderUid'] as String?,
          );
          groupTitleOverride = '${group?.name ?? 'Group'} • $senderName';
          chatIdOverride = fetchedGroupId;
        }
      }
    } catch (_) {
      debugPrint('[AirChat][bg] enrich failed');
    }
    await _showWakeNotification(
      message,
      bodyOverride: realText,
      titleOverride: groupTitleOverride,
      chatIdOverride: chatIdOverride,
    );
    debugPrint('[AirChat][bg] wake notification shown');
  } catch (e, st) {
    debugPrint('[AirChat][bg] handler failed');
    CrashReporter.recordError(
      error: _redactError(e.toString()),
      stackTrace: st,
      source: 'fcm-bg',
    );
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
    debugPrint('[AirChat][bg] delivery_failed handling failed');
    CrashReporter.recordError(
      error: _redactError(e.toString()),
      stackTrace: st,
      source: 'delivery-failed',
    );
  }
}

/// A message pulled from the relay's background queue: the notification
/// preview text plus the group it actually belongs to (null for a genuine 1:1
/// message).
class _FetchedMessage {
  final String text;
  final String? groupId;
  const _FetchedMessage(this.text, {this.groupId});
}

/// Connects the tunnel briefly to pull the queued encrypted message from the
/// relay, decrypts it, persists it locally, and returns the notification
/// preview (plus the group it belongs to, when the payload is a group
/// message).
/// Uses a raw pure-Dart WebSocket (no plugins — guaranteed to work in a
/// background isolate where plugin registration is unavailable).
/// Time-boxed — returns null on any failure/timeout.
Future<_FetchedMessage?> _fetchQueuedMessage(RemoteMessage message) async {
  final data = message.data;
  final senderUid = data['senderUid'] as String?;
  if (senderUid == null || senderUid.isEmpty) return null;

  final myUid = await KeyStore.getUid();
  final keyPair = await KeyStore.getKeyPair();
  if (myUid == null || myUid.isEmpty || keyPair == null) return null;

  await AppDatabase.instance;

  final engine = SodiumEngine();
  final completer = Completer<_FetchedMessage?>();
  Timer(const Duration(seconds: 15), () {
    if (!completer.isCompleted) completer.complete(null);
  });

  debugPrint('[AirChat][bg] fetch: connect as $myUid');
  final channel = WebSocketChannel.connect(
    Uri.parse(
      'wss://airchat-relay.malandkar-sarvesh1.workers.dev/tunnel?uid=$myUid',
    ),
  );
  channel.ready
      .then((_) {
        debugPrint('[AirChat][bg] ws ready');
      })
      .catchError((_) {
        debugPrint('[AirChat][bg] ws ready failed');
      });
  late final StreamSubscription<dynamic> sub;
  sub = channel.stream.listen(
    (raw) {
      final rawStr = raw is String ? raw : utf8.decode(raw as List<int>);
      try {
        final msg = jsonDecode(rawStr) as Map<String, dynamic>;
        // Relay auth: sign the challenge so the inbox actually flushes.
        if (msg['type'] == 'auth_challenge') {
          Future(() async {
            final sig = await signRelayChallenge(
              myUid,
              msg['nonce'] as String? ?? '',
            );
            if (sig != null && sig.isNotEmpty) {
              channel.sink.add(
                jsonEncode({'action': 'auth', 'signature': sig}),
              );
            }
          });
          return;
        }
        if (msg['type'] != 'direct_message') return;
        if (msg['senderUid'] != senderUid) return;

        final cryptoPayload = CryptoPayload.decode(msg['payload'] as String);
        Future(() async {
          try {
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

            final payloadGroupId = decoded['groupId'] as String?;
            final isGroupMsg =
                payloadGroupId != null && payloadGroupId.isNotEmpty;

            final chatId = isGroupMsg
                ? payloadGroupId
                : buildChatId(myUid, senderUid);

            String groupSenderName = '';
            if (isGroupMsg) {
              groupSenderName = decoded['senderName'] as String? ?? '';
              if (groupSenderName.isEmpty) {
                final contact = await ContactDao().getContactByUid(senderUid);
                if (contact != null && contact.username.isNotEmpty) {
                  groupSenderName = contact.username;
                }
              }
            }

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
                groupId: isGroupMsg ? payloadGroupId : null,
                groupSenderName: isGroupMsg ? groupSenderName : null,
              ),
            );

            if (!isGroupMsg) {
              await ChatDao().updatePreviewPreservingUnread(
                ChatThread(
                  id: chatId,
                  contactUid: senderUid,
                  lastMessage: text.isEmpty ? '\u{1F4CE} $type' : text,
                  lastMessageTime: timestamp,
                ),
              );
              await ChatDao().incrementUnread(chatId);
            }
            // Ack so the relay deletes the queued copy.
            channel.sink.add(
              jsonEncode({
                'action': 'ack',
                if (packetId != null) 'packetId': packetId,
                'senderUid': senderUid,
              }),
            );
            if (!completer.isCompleted) {
              completer.complete(
                _FetchedMessage(
                  text.isEmpty ? '\u{1F4CE} $type' : text,
                  groupId: isGroupMsg ? payloadGroupId : null,
                ),
              );
            }
          } catch (_) {
            debugPrint('[AirChat][bg] fetch decrypt/persist failed');
          }
        });
      } catch (_) {
        debugPrint('[AirChat][bg] ws msg failed');
      }
    },
    onError: (_) {
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

/// Fetches a group message from the relay's group inbox.
/// The relay stores group packets in `grp:<groupId>:<packetId>` and flushes
/// them all when any member connects. This function connects, receives the
/// flushed group_packet messages, decrypts with the local groupKey, persists,
/// and returns the notification preview text.
Future<String?> _fetchGroupMessage(RemoteMessage message) async {
  final data = message.data;
  final groupId = data['groupId'] as String?;
  final senderName = data['senderName'] as String? ?? '';

  if (groupId == null || groupId.isEmpty) return null;

  final myUid = await KeyStore.getUid();
  if (myUid == null || myUid.isEmpty) return null;

  await AppDatabase.instance;

  // Look up the local group and its symmetric key.
  final localGroup = await GroupDao().getGroupById(groupId);
  if (localGroup == null) return null; // unknown group
  final groupKey = localGroup.groupKey;
  if (groupKey == null || groupKey.isEmpty) return null;

  final engine = SodiumEngine();
  final completer = Completer<String?>();
  Timer(const Duration(seconds: 15), () {
    if (!completer.isCompleted) completer.complete(null);
  });

  debugPrint('[AirChat][bg] group fetch: connect as $myUid');
  final channel = WebSocketChannel.connect(
    Uri.parse(
      'wss://airchat-relay.malandkar-sarvesh1.workers.dev/tunnel?uid=$myUid',
    ),
  );
  channel.ready
      .then((_) => debugPrint('[AirChat][bg] group ws ready'))
      .catchError((_) => debugPrint('[AirChat][bg] group ws ready failed'));

  late final StreamSubscription<dynamic> sub;
  sub = channel.stream.listen(
    (raw) {
      final rawStr = raw is String ? raw : utf8.decode(raw as List<int>);
      try {
        final msg = jsonDecode(rawStr) as Map<String, dynamic>;
        // Relay auth: sign the challenge so the inbox actually flushes.
        if (msg['type'] == 'auth_challenge') {
          Future(() async {
            final sig = await signRelayChallenge(
              myUid,
              msg['nonce'] as String? ?? '',
            );
            if (sig != null && sig.isNotEmpty) {
              channel.sink.add(
                jsonEncode({'action': 'auth', 'signature': sig}),
              );
            }
          });
          return;
        }
        if (msg['type'] != 'group_packet') return;
        if (msg['groupId'] != groupId) return; // wrong group

        final senderUid = msg['senderUid'] as String? ?? '';
        final packetId = msg['packetId'] as String? ?? '';
        final encodedPayload = msg['payload'] as String? ?? '';
        final msgSenderName = msg['senderName'] as String? ?? '';
        final timestamp =
            (msg['timestamp'] as int?) ?? DateTime.now().millisecondsSinceEpoch;

        if (encodedPayload.isEmpty) return;

        Future(() async {
          try {
            final cryptoPayload = CryptoPayload.decode(encodedPayload);
            final decrypted = await engine.decryptGroupMessage(
              payload: cryptoPayload,
              groupKeyBase64: groupKey,
            );
            final decoded = jsonDecode(decrypted);
            final text = (decoded['text'] as String?) ?? '';
            final type = (decoded['type'] as String?) ?? 'text';

            // Resolve sender name: prefer payload > relay > contact > fallback.
            String resolvedName =
                decoded['senderName'] as String? ?? msgSenderName;
            if (resolvedName.isEmpty) {
              try {
                final contact = await ContactDao().getContactByUid(senderUid);
                if (contact != null && contact.username.isNotEmpty) {
                  resolvedName = contact.username;
                }
              } catch (_) {}
            }
            if (resolvedName.isEmpty) {
              resolvedName = senderUid.length > 8
                  ? senderUid.substring(senderUid.length - 8)
                  : senderUid;
            }

            // Persist as a group message.
            await MessageDao().insertMessage(
              ChatMessage(
                id: packetId.isNotEmpty ? packetId : 'grp_bg_$timestamp',
                chatId: groupId,
                senderUid: senderUid,
                recipientUid: myUid,
                text: text,
                type: type,
                timestamp: timestamp,
                isMe: false,
                status: 'delivered',
                groupId: groupId,
                groupSenderName: resolvedName,
                replyToId: (decoded['replyTo']?['id'] as String?),
                replyText: (decoded['replyTo']?['text'] as String?) ?? '',
                replyType: (decoded['replyTo']?['type'] as String?) ?? 'text',
                replyIsMe: decoded['replyTo']?['isMe'] as bool?,
              ),
            );

            // ACK the group packet.
            channel.sink.add(
              jsonEncode({
                'action': 'ack_group',
                'packetId': packetId,
                'groupId': groupId,
              }),
            );

            if (!completer.isCompleted) {
              completer.complete(
                '$resolvedName: ${text.isEmpty ? '\u{1F4CE} $type' : text}',
              );
            }
          } catch (_) {
            debugPrint('[AirChat][bg] group decrypt/persist failed');
          }
        }).catchError((_) {
          debugPrint('[AirChat][bg] group message processing failed');
        });
      } catch (_) {
        debugPrint('[AirChat][bg] group ws msg failed');
      }
    },
    onError: (_) {
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
    '[AirChat][bg] group fetch result: ${result != null ? 'got text' : 'timeout'}',
  );
  // Fallback: show sender name even if decryption failed.
  return result ??
      (senderName.isNotEmpty ? '$senderName sent a message' : null);
}

/// Minimal redaction helpers for local diagnostic logs. These are not crypto
/// boundaries; they just keep log lines short and avoid dumping raw network/
/// relay objects into crash logs.
String _redactError(String s) {
  if (s.length <= 200) return s;
  return s.substring(0, 200);
}
