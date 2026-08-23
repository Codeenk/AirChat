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

  MessageRouter({
    required this.uid,
    required this.client,
    required this.engine,
    required this.messageDao,
    required this.chatDao,
    required this.contactDao,
    required this.bus,
  });

  void start() {
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

      // ---- Auto-contact: unknown sender is resolved via directory and
      // added locally, so the recipient can see AND reply immediately
      // without scanning back. ----
      final existing = await contactDao.getContactByUid(senderUid);
      if (existing == null) {
        String username;
        String publicKey;
        try {
          final info = await const ApiClient().lookupIdentity(uid: senderUid);
          username = (info?['username'] as String?) ?? _fallbackName(senderUid);
          publicKey = (info?['identity_public_key'] as String?) ?? '';
        } catch (_) {
          username = _fallbackName(senderUid);
          publicKey = '';
        }
        await contactDao.insertContact(Contact(
          uid: senderUid,
          username: username,
          identityPublicKey: publicKey,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      } else if (_isFallbackName(existing.username)) {
        // Self-heal: upgrade placeholder names (peer_xxxx / airchat_xxxx)
        // to the sender's real directory username once it exists.
        try {
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
          }
        } catch (_) {}
      }

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
      await chatDao.insertOrUpdateChat(ChatThread(
        id: chatId,
        contactUid: senderUid,
        lastMessage: text.isEmpty ? '📎 $messageType' : text,
        lastMessageTime: timestamp,
      ));

      // Notify live UI surfaces (open chat, home list) instantly
      bus.fire(RefreshEvent(type: 'messages', chatId: chatId));

      // Background/terminated: surface a visible local notification with the
      // sender's display name and a message preview.
      if (!NotificationService.isAppForeground) {
        final contact = await contactDao.getContactByUid(senderUid);
        final senderName =
            contact?.username ?? _fallbackName(senderUid);
        await NotificationService.instance.showMessageNotification(
          title: senderName,
          body: text.isEmpty ? '📎 $messageType' : text,
        );
      }
    } catch (e) {
      // Decryption failed or message already stored
    }
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

  client.connect();
  client.messageStream.listen(router._onMessage);

  return router;
});
