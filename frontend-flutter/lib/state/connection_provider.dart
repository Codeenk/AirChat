import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/crypto/key_store.dart';
import '../core/crypto/sodium_engine.dart';
import '../core/database/daos/chat_dao.dart';
import '../core/database/daos/contact_dao.dart';
import '../core/database/daos/message_dao.dart';
import '../core/network/push_service.dart';
import '../core/network/api_client.dart';
import '../core/network/notification_service.dart';
import '../core/network/websocket_client.dart';
import '../models/chat_thread.dart';
import '../models/contact.dart';
import '../models/message_payload.dart';
import 'refresh_bus.dart';

final currentUidProvider = StateProvider<String>((ref) => '');

final refreshBusProvider = Provider((ref) {
  final bus = RefreshBus();
  ref.onDispose(() => bus.dispose());
  return bus;
});

final firebaseInitializerProvider = FutureProvider((ref) async {
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: 'AIzaSyBrybxVHpsFDe0wd6CQ7P4qpdxXsosnWc8',
      appId: '1:933764476354:android:365fe94c303a466c9aba5b',
      messagingSenderId: '933764476354',
      projectId: 'airchat-messaging',
    ),
  );
  return null;
});

final pushServiceProvider = Provider<PushService>((ref) {
  return PushService(const ApiClient());
});

final contactDaoProvider = Provider((_) => ContactDao());
final chatDaoProvider = Provider((_) => ChatDao());
final messageDaoProvider = Provider((_) => MessageDao());
final sodiumEngineProvider = Provider((_) => SodiumEngine());

final websocketClientProvider = Provider.family<WebSocketTunnelClient, String>((ref, uid) {
  final client = WebSocketTunnelClient(uid: uid);
  ref.onDispose(() => client.dispose());
  return client;
});

final tunnelStateProvider = StreamProvider.family<TunnelState, String>((ref, uid) async* {
  final client = ref.watch(websocketClientProvider(uid));
  // Replay current state first — late subscribers (opened screens) see truth
  // immediately instead of a stale 'Connecting' until the next event.
  yield client.currentState;
  await for (final state in client.stateStream) {
    yield state;
  }
});

class MessageRouter {
  final String uid;
  final WebSocketTunnelClient client;
  final SodiumEngine engine;
  final MessageDao messageDao;
  final ChatDao chatDao;
  final ContactDao contactDao;
  final RefreshBus bus;

  /// Chat screen the user currently has open (null = home/none). Used to
  /// decide whether incoming messages can be marked as read immediately.
  static String? openChatId;

  bool _started = false;

  MessageRouter({
    required this.uid,
    required this.client,
    required this.engine,
    required this.messageDao,
    required this.chatDao,
    required this.contactDao,
    required this.bus,
  });

  /// Idempotent start — safe to call multiple times without duplicating
  /// WebSocket connections or stream listeners.
  void start() {
    if (_started) return;
    _started = true;
    client.connect();
    client.messageStream.listen(_onMessage);
  }

  void _onMessage(Map<String, dynamic> msg) {
    try {
      final type = msg['type'];
      if (type == 'direct_message') {
        _handleDirectMessage(msg);
      } else if (type == 'packet_status') {
        final packetId = msg['packetId'] as String?;
        final status = msg['status'] as String?;
        if (packetId != null && status != null) {
          messageDao.updateMessageStatus(packetId, status);
          bus.fire(RefreshEvent(
            type: 'status',
            messageId: packetId,
            status: status,
          ));
        }
      } else if (type == 'read_receipt') {
        final packetId = msg['packetId'] as String?;
        if (packetId != null) {
          messageDao.updateMessageStatus(packetId, 'read');
          bus.fire(RefreshEvent(
            type: 'status',
            messageId: packetId,
            status: 'read',
          ));
        }
      } else if (type == 'delivery_failed') {
        // 24h ephemeral cache expired — the message was destroyed server-side
        // and never reached the recipient. Mark honestly as expired.
        final packetIds = (msg['packetIds'] as List<dynamic>?) ?? const [];
        for (final id in packetIds) {
          if (id is String && id.isNotEmpty) {
            messageDao.updateMessageStatus(id, 'expired');
            bus.fire(RefreshEvent(
              type: 'status',
              messageId: id,
              status: 'expired',
            ));
          }
        }
      } else if (type == 'delivery_receipt') {
        final packetId = msg['packetId'] as String?;
        if (packetId != null) {
          messageDao.updateMessageStatus(packetId, 'delivered');
          bus.fire(RefreshEvent(
            type: 'status',
            messageId: packetId,
            status: 'delivered',
          ));
        }
      }
    } catch (_) {
      // Ignore message processing errors to keep stream alive
    }
  }

  Future<void> _handleDirectMessage(Map<String, dynamic> msg) async {
    final senderUid = msg['senderUid'] as String?;
    final packetId = msg['packetId'] as String?;
    final encodedPayload = msg['payload'] as String?;
    final timestamp = msg['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    if (senderUid == null || packetId == null || encodedPayload == null) return;

    final keyPair = await KeyStore.getKeyPair();
    if (keyPair == null) return;

    try {
      final cryptoPayload = CryptoPayload.decode(encodedPayload);
      final decrypted = await engine.decryptMessage(
        payload: cryptoPayload,
        recipientKeyPair: keyPair,
      );

      final decoded = jsonDecode(decrypted);
      final messageType = decoded['type'] ?? 'text';
      final text = decoded['text'] ?? '';
      final mediaKey = decoded['mediaKey'];
      final secretKeyHex = decoded['secretKeyHex'];
      final nonceHex = decoded['nonceHex'];
      final replyTo =
          (decoded['replyTo'] as Map<String, dynamic>?) ?? const {};

      final chatId = _chatId(uid, senderUid);

      // Resolve contact name inline (fast, no network) — use fallback if unknown.
      final existing = await contactDao.getContactByUid(senderUid);
      String contactName;
      if (existing != null && !_isFallbackName(existing.username)) {
        contactName = existing.username;
      } else {
        contactName = _fallbackName(senderUid);
      }

      // Store message IMMEDIATELY — never block on network lookups.
      final message = ChatMessage(
        id: packetId,
        chatId: chatId,
        senderUid: senderUid,
        recipientUid: uid,
        text: text,
        mediaKey: mediaKey,
        secretKeyHex: secretKeyHex,
        nonceHex: nonceHex,
        type: messageType,
        timestamp: timestamp,
        isMe: false,
        status: 'delivered',
        replyToId: replyTo['id'] as String?,
        replyText: (replyTo['text'] as String?) ?? '',
        replyType: (replyTo['type'] as String?) ?? 'text',
        replyIsMe: replyTo['isMe'] as bool?,
      );

      await messageDao.insertMessage(message);
      final chatOpen = MessageRouter.openChatId == chatId;
      await chatDao.updatePreviewPreservingUnread(ChatThread(
        id: chatId,
        contactUid: senderUid,
        lastMessage: text.isEmpty ? '📎 $messageType' : text,
        lastMessageTime: timestamp,
      ));

      // Unread badge: only count messages that arrived outside the open chat.
      if (!chatOpen) {
        await chatDao.incrementUnread(chatId);
      }

      // Notify live UI surfaces (open chat, home list) instantly
      bus.fire(RefreshEvent(type: 'messages', chatId: chatId));

      // Chat is open & visible → the user has effectively read it already.
      // Send a read receipt so the sender's ticks advance honestly.
      if (NotificationService.isAppForeground && MessageRouter.openChatId == chatId) {
        client.sendReadReceipt(packetId: packetId, senderUid: senderUid);
      }

      // Background/terminated: stacked per-sender notification (MessagingStyle).
      if (!NotificationService.isAppForeground) {
        await NotificationService.instance.showMessageNotification(
          title: contactName,
          body: text.isEmpty ? '📎 $messageType' : text,
          senderUid: senderUid,
        );
      }

      // Background directory resolution — never blocks message delivery.
      _resolveContactInBackground(senderUid);
    } catch (e) {
      // Decryption failed or message already stored
    }
  }

  /// Fire-and-forget: resolve or upgrade contact name from directory.
  /// Updates local DB and fires a RefreshBus event so UI surfaces pick up
  /// the real name without blocking message processing.
  void _resolveContactInBackground(String senderUid) async {
    try {
      final existing = await contactDao.getContactByUid(senderUid);
      if (existing == null) {
        final info = await const ApiClient().lookupIdentity(uid: senderUid);
        final username = (info?['username'] as String?) ?? _fallbackName(senderUid);
        final publicKey = (info?['identity_public_key'] as String?) ?? '';
        await contactDao.insertContact(Contact(
          uid: senderUid,
          username: username,
          identityPublicKey: publicKey,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
        bus.fire(RefreshEvent(type: 'messages'));
      } else if (_isFallbackName(existing.username)) {
        final info = await const ApiClient().lookupIdentity(uid: senderUid);
        final realName = info?['username'] as String?;
        if (realName != null &&
            realName.isNotEmpty &&
            realName != existing.username) {
          await contactDao.insertContact(Contact(
            uid: existing.uid,
            username: realName,
            identityPublicKey: existing.identityPublicKey,
            createdAt: existing.createdAt,
          ));
          bus.fire(RefreshEvent(type: 'messages'));
        }
      }
    } catch (_) {}
  }

  String _chatId(String myUid, String peerUid) {
    final ids = [myUid, peerUid]..sort();
    return ids.join('_');
  }

  String _fallbackName(String uid) =>
      'peer_${uid.length > 8 ? uid.substring(uid.length - 8) : uid}';

  bool _isFallbackName(String name) {
    if (name.isEmpty) return true;
    if (name == 'Peer' || name.startsWith('peer_')) return true;
    if (name.startsWith('airchat_') && name.length >= 12) return true;
    return false;
  }
}

final messageRouterProvider = Provider.family<MessageRouter, String>((ref, uid) {
  final client = ref.watch(websocketClientProvider(uid));
  final engine = ref.watch(sodiumEngineProvider);
  final router = MessageRouter(
    uid: uid,
    client: client,
    engine: engine,
    messageDao: ref.watch(messageDaoProvider),
    chatDao: ref.watch(chatDaoProvider),
    contactDao: ref.watch(contactDaoProvider),
    bus: ref.watch(refreshBusProvider),
  );

  // Idempotent start — safe even if provider is rebuilt (won't duplicate
  // WebSocket connections or stream listeners).
  router.start();

  // Prevent this provider from being disposed on last listener removal.
  // The MessageRouter owns a WebSocket connection that must persist for
  // the app lifetime.
  ref.keepAlive();

  return router;
});
