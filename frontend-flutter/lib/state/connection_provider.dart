import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crash/crash_reporter.dart';
import '../core/crypto/key_store.dart';
import '../core/crypto/relay_auth.dart';
import '../core/crypto/signing_engine.dart';
import '../core/crypto/sodium_engine.dart';
import '../core/database/daos/chat_dao.dart';
import '../core/database/daos/contact_dao.dart';
import '../core/database/daos/message_dao.dart';
import '../core/network/push_service.dart';
import '../core/network/api_client.dart';
import '../core/network/message_status.dart';
import '../core/network/notification_service.dart';
import '../core/network/websocket_client.dart';
import '../models/chat_thread.dart';
import '../models/contact.dart';
import '../models/group.dart';
import '../models/message_payload.dart';
import '../core/database/daos/group_dao.dart';
import 'refresh_bus.dart';

final currentUidProvider = StateProvider<String>((ref) => '');

final refreshBusProvider = Provider((ref) {
  final bus = RefreshBus();
  ref.onDispose(() => bus.dispose());
  return bus;
});

final firebaseInitializerProvider = FutureProvider((ref) async {
  // Idempotent: main() may have already brought Firebase up so the FCM
  // background handler could be registered before runApp.
  if (Firebase.apps.isNotEmpty) return null;
  if (kIsWeb || defaultTargetPlatform == TargetPlatform.android) {
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'AIzaSyBrybxVHpsFDe0wd6CQ7P4qpdxXsosnWc8',
        appId: '1:933764476354:android:365fe94c303a466c9aba5b',
        messagingSenderId: '933764476354',
        projectId: 'airchat-messaging',
      ),
    );
  } else {
    // iOS/macOS: config comes from GoogleService-Info.plist in the bundle.
    await Firebase.initializeApp();
  }
  return null;
});

final pushServiceProvider = Provider<PushService>((ref) {
  return PushService(const ApiClient());
});

final contactDaoProvider = Provider((_) => ContactDao());
final chatDaoProvider = Provider((_) => ChatDao());
final messageDaoProvider = Provider((_) => MessageDao());
final sodiumEngineProvider = Provider((_) => SodiumEngine());

/// Last auth-failure-triggered re-register, to avoid hammering the
/// directory on every reconnect cycle while the key is missing.
DateTime? _lastAuthHealAt;

final websocketClientProvider = Provider.family<WebSocketTunnelClient, String>((
  ref,
  uid,
) {
  final client = WebSocketTunnelClient(
    uid: uid,
    signChallenge: (nonce) => signRelayChallenge(uid, nonce),
    onAuthFailure: () async {
      // The relay rejected our auth — almost always a missing/stale signing
      // key server-side. Re-register (upsert) so the directory holds our
      // current key, then the normal reconnect cycle heals. Cooldown 5 min.
      final now = DateTime.now();
      if (_lastAuthHealAt != null &&
          now.difference(_lastAuthHealAt!).inMinutes < 5) {
        return;
      }
      _lastAuthHealAt = now;
      try {
        var signingKp = await KeyStore.getSigningKeyPair();
        if (signingKp == null) {
          final engine = SigningEngine();
          signingKp = await engine.generateSigningKeyPair();
          await KeyStore.saveSigningKeyPair(signingKp);
        }
        final pubKey = await KeyStore.getPublicKey() ?? '';
        if (pubKey.isEmpty) return;
        await const ApiClient().registerIdentity(
          uid: uid,
          username: await KeyStore.getUsername() ?? '',
          identityPublicKey: pubKey,
        );
      } catch (_) {}
    },
  );
  ref.onDispose(() => client.dispose());
  return client;
});

final tunnelStateProvider = StreamProvider.family<TunnelState, String>((
  ref,
  uid,
) async* {
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
      } else if (type == 'group_packet') {
        _handleGroupPacket(msg);
      } else if (type == 'packet_status') {
        final packetId = msg['packetId'] as String?;
        final status = msg['status'] as String?;
        // Map relay vocabulary (relayed/queued_ephemeral) to what the UI
        // actually renders — never let it fall through to "read".
        final mapped = status == null ? null : mapRelayStatus(status);
        if (packetId != null && mapped != null) {
          messageDao.updateMessageStatus(packetId, mapped);
          bus.fire(
            RefreshEvent(type: 'status', messageId: packetId, status: mapped),
          );
        }
      } else if (type == 'read_receipt') {
        final packetId = msg['packetId'] as String?;
        if (packetId != null) {
          messageDao.updateMessageStatus(packetId, 'read');
          bus.fire(
            RefreshEvent(type: 'status', messageId: packetId, status: 'read'),
          );
        }
      } else if (type == 'delivery_failed') {
        // 24h ephemeral cache expired — the message was destroyed server-side
        // and never reached the recipient. Mark honestly as expired.
        final packetIds = (msg['packetIds'] as List<dynamic>?) ?? const [];
        for (final id in packetIds) {
          if (id is String && id.isNotEmpty) {
            messageDao.updateMessageStatus(id, 'expired');
            bus.fire(
              RefreshEvent(type: 'status', messageId: id, status: 'expired'),
            );
          }
        }
      } else if (type == 'delivery_receipt') {
        final packetId = msg['packetId'] as String?;
        if (packetId != null) {
          messageDao.updateMessageStatus(packetId, 'delivered');
          bus.fire(
            RefreshEvent(
              type: 'status',
              messageId: packetId,
              status: 'delivered',
            ),
          );
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
    final timestamp =
        msg['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    if (senderUid == null || packetId == null || encodedPayload == null) return;

    // Replay window: drop messages older than the 24h cache TTL (+1h skew)
    // or more than 5min in the future (clock games / replay injection).
    final now = DateTime.now().millisecondsSinceEpoch;
    if (timestamp < now - 25 * 60 * 60 * 1000 ||
        timestamp > now + 5 * 60 * 1000) {
      CrashReporter.recordError(
        error: 'replay/out-of-window dropped from $senderUid',
        source: 'replay-guard',
      );
      return;
    }

    final keyPair = await KeyStore.getKeyPair();
    if (keyPair == null) return;

    try {
      final cryptoPayload = CryptoPayload.decode(encodedPayload);
      final decrypted = await engine.decryptMessage(
        payload: cryptoPayload,
        recipientKeyPair: keyPair,
      );

      final decoded = jsonDecode(decrypted) as Map<String, dynamic>;
      final messageType = decoded['type'] ?? 'text';
      final text = decoded['text'] ?? '';
      final mediaKey = decoded['mediaKey'];
      final secretKeyHex = decoded['secretKeyHex'];
      final nonceHex = decoded['nonceHex'];
      final replyTo = (decoded['replyTo'] as Map<String, dynamic>?) ?? const {};
      final groupId = decoded['groupId'] as String?;
      final groupName = decoded['groupName'] as String?;

      // Group control messages: create/update local group, no chat bubble.
      if (messageType == 'group_invite' ||
          messageType == 'group_add' ||
          messageType == 'group_kick') {
        // Verify the control signature — roster changes from anyone but a
        // member are dropped (relay spoofing / outsider injection).
        // Missing sig = legacy client → accept (rollout compat).
        if (decoded['sig'] != null) {
          final ctrlMembers =
              (decoded['memberUids'] as List<dynamic>?)?.cast<String>() ?? [];
          final ctrlGid = decoded['groupId'] as String? ?? '';
          final directOk = await _verifyControlSender(
            senderUid: senderUid,
            type: messageType,
            groupId: ctrlGid,
            memberUids: ctrlMembers,
            signature: decoded['sig'] as String?,
          );
          if (!directOk) {
            CrashReporter.recordError(
              error: 'group control sig invalid from $senderUid',
              source: 'group-verify',
            );
            return;
          }
        }

        final gid = groupId ?? decoded['groupId'] as String? ?? '';
        final gname = groupName ?? decoded['groupName'] as String? ?? 'Group';
        final memberUids =
            (decoded['memberUids'] as List<dynamic>?)?.cast<String>() ?? [];
        final receivedGroupKey = decoded['groupKey'] as String?;
        if (gid.isNotEmpty) {
          if (messageType == 'group_kick' &&
              (decoded['kickedUid'] as String? ?? '') == uid) {
            await GroupDao().deleteGroup(gid);
          } else {
            final wasKick = messageType == 'group_kick';
            // If we already have this group locally, preserve the existing groupKey
            // unless the incoming payload carries a new one (key rotation).
            final existing = await GroupDao().getGroupById(gid);
            final effectiveKey = receivedGroupKey ?? existing?.groupKey;
            await GroupDao().insertGroup(
              Group(
                id: gid,
                name: gname,
                memberUids: memberUids.isEmpty ? [uid, senderUid] : memberUids,
                createdAt: timestamp,
                groupKey: effectiveKey,
              ),
            );
            // A kick changed the roster: survivors must rotate the key so the
            // removed member's copy dies. The rotating broadcast carries the
            // new key (see GroupActions.rotateGroupKey).
            if (wasKick) {
              bus.fire(RefreshEvent(type: 'rekey', chatId: gid));
            }
          }
          bus.fire(RefreshEvent(type: 'messages', chatId: gid));
        }
        return;
      }

      final isGroup = groupId != null && groupId.isNotEmpty;
      if (groupId != null && groupId.isNotEmpty) {
        final localGroup = await GroupDao().getGroupById(groupId);
        if (localGroup != null && !localGroup.memberUids.contains(senderUid)) {
          // Sender was removed/left — ignore their stale messages.
          return;
        }
      }
      final chatId = (groupId != null && groupId.isNotEmpty)
          ? groupId
          : _chatId(uid, senderUid);

      // Sender authenticity: verify the Ed25519 signature over
      // `packetId|text|chatId`. A hostile relay knows every recipient's public
      // key and could otherwise synthesize a ciphertext "from" any sender.
      // Missing sig = legacy client (accepted during rollout); invalid = drop.
      final directSig = decoded['sig'] as String?;
      if (directSig != null && directSig.isNotEmpty) {
        final directOk = await _verifyDirectSender(
          senderUid: senderUid,
          packetId: packetId,
          text: text,
          chatId: chatId,
          signature: directSig,
        );
        if (!directOk) {
          CrashReporter.recordError(
            error: 'direct sig invalid from $senderUid',
            source: 'direct-verify',
          );
          return;
        }
      }

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
        type: isGroup ? 'text' : messageType,
        timestamp: timestamp,
        isMe: false,
        status: 'delivered',
        replyToId: replyTo['id'] as String?,
        replyText: (replyTo['text'] as String?) ?? '',
        replyType: (replyTo['type'] as String?) ?? 'text',
        replyIsMe: replyTo['isMe'] as bool?,
        groupId: isGroup ? groupId : null,
        groupSenderName: isGroup ? contactName : null,
      );

      await messageDao.insertMessage(message);

      if (isGroup) {
        if (MessageRouter.openChatId != chatId) {
          await GroupDao().incrementUnread(chatId);
        }
        bus.fire(RefreshEvent(type: 'messages', chatId: chatId));
        if (!NotificationService.isAppForeground) {
          final gname = groupName ?? 'Group';
          await NotificationService.instance.showMessageNotification(
            title: '$gname • $contactName',
            body: text.isEmpty ? '📎 $messageType' : text,
            senderUid: chatId,
          );
        }
      } else {
        final chatOpen = MessageRouter.openChatId == chatId;
        await chatDao.updatePreviewPreservingUnread(
          ChatThread(
            id: chatId,
            contactUid: senderUid,
            lastMessage: text.isEmpty ? '📎 $messageType' : text,
            lastMessageTime: timestamp,
          ),
        );

        if (!chatOpen) {
          await chatDao.incrementUnread(chatId);
        }

        bus.fire(RefreshEvent(type: 'messages', chatId: chatId));

        if (NotificationService.isAppForeground &&
            MessageRouter.openChatId == chatId) {
          client.sendReadReceipt(packetId: packetId, senderUid: senderUid);
        }

        if (!NotificationService.isAppForeground) {
          await NotificationService.instance.showMessageNotification(
            title: contactName,
            body: text.isEmpty ? '📎 $messageType' : text,
            senderUid: senderUid,
          );
        }
      }

      // Background directory resolution — never blocks message delivery.
      _resolveContactInBackground(senderUid);
    } catch (e) {
      // Decryption failed or message already stored
    }
  }

  /// Handles a group_packet pushed by the relay — encrypted with the shared
  /// groupKey, addressed to the group inbox (not to an individual user).
  Future<void> _handleGroupPacket(Map<String, dynamic> msg) async {
    final senderUid = msg['senderUid'] as String? ?? '';
    final packetId = msg['packetId'] as String? ?? '';
    final encodedPayload = msg['payload'] as String? ?? '';
    final groupId = msg['groupId'] as String? ?? '';
    final senderNameFromRelay = msg['senderName'] as String? ?? '';
    final timestamp =
        msg['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    if (groupId.isEmpty || encodedPayload.isEmpty) return;

    // Replay window (same policy as 1:1).
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (timestamp < nowMs - 25 * 60 * 60 * 1000 ||
        timestamp > nowMs + 5 * 60 * 1000) {
      CrashReporter.recordError(
        error: 'group replay/out-of-window dropped from $senderUid',
        source: 'replay-guard',
      );
      return;
    }

    // Look up the local group and its symmetric groupKey.
    final localGroup = await GroupDao().getGroupById(groupId);
    if (localGroup == null) return; // group not known locally — ignore
    if (!localGroup.memberUids.contains(senderUid))
      return; // sender was removed
    final groupKey = localGroup.groupKey;
    if (groupKey == null || groupKey.isEmpty) return; // no key available

    try {
      final cryptoPayload = CryptoPayload.decode(encodedPayload);
      final decrypted = await engine.decryptGroupMessage(
        payload: cryptoPayload,
        groupKeyBase64: groupKey,
      );

      final decoded = jsonDecode(decrypted) as Map<String, dynamic>;
      final text = decoded['text'] ?? '';
      final messageType = decoded['type'] ?? 'text';
      final mediaKey = decoded['mediaKey'];
      final secretKeyHex = decoded['secretKeyHex'];
      final nonceHex = decoded['nonceHex'];
      final replyTo = (decoded['replyTo'] as Map<String, dynamic>?) ?? const {};

      // Verify sender signature (drops relay/member spoofing).
      final sigOk = await _verifyGroupSender(
        senderUid: senderUid,
        packetId: packetId,
        text: text,
        groupId: groupId,
        signature: decoded['sig'] as String?,
      );
      if (!sigOk) {
        CrashReporter.recordError(
          error: 'group sig invalid from $senderUid in $groupId',
          source: 'group-verify',
        );
        return;
      }

      // Resolve sender name: prefer the name in the payload, then relay, then contact.
      String contactName =
          decoded['senderName'] as String? ?? senderNameFromRelay;
      if (contactName.isEmpty) {
        final existing = await contactDao.getContactByUid(senderUid);
        if (existing != null && !_isFallbackName(existing.username)) {
          contactName = existing.username;
        } else {
          contactName = _fallbackName(senderUid);
        }
      }

      final message = ChatMessage(
        id: packetId,
        chatId: groupId,
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
        groupId: groupId,
        groupSenderName: contactName,
      );

      await messageDao.insertMessage(message);
      bus.fire(RefreshEvent(type: 'messages', chatId: groupId));

      if (!NotificationService.isAppForeground) {
        await NotificationService.instance.showMessageNotification(
          title: '${localGroup.name} • $contactName',
          body: text.isEmpty ? '📎 $messageType' : text,
          senderUid: groupId,
        );
      }

      // ACK the group packet so the relay deletes the cached copy.
      client.ackGroupPacket(packetId: packetId, groupId: groupId);
    } catch (e) {
      // Decryption failed or message already stored
    }
  }

  /// Verifies a 1:1 payload signature: Ed25519(packetId|text|chatId).
  /// Fetches + caches the sender's signing key from the directory on demand.
  Future<bool> _verifyDirectSender({
    required String senderUid,
    required String packetId,
    required String text,
    required String chatId,
    required String? signature,
  }) async {
    if (signature == null || signature.isEmpty) return true;
    try {
      final signingKey = await _resolveSigningKey(senderUid);
      if (signingKey == null || signingKey.isEmpty) return true;
      return await SigningEngine().verifyHex(
        message: '$packetId|$text|$chatId',
        signatureHex: signature,
        publicKeyHex: signingKey,
      );
    } catch (_) {
      return false;
    }
  }

  /// Resolves (and caches into the contacts DB) a peer's Ed25519 signing key.
  Future<String?> _resolveSigningKey(String senderUid) async {
    final contact = await contactDao.getContactByUid(senderUid);
    var signingKey = contact?.signingPublicKey;
    if (signingKey != null && signingKey.isNotEmpty) return signingKey;
    final info = await const ApiClient().lookupIdentity(uid: senderUid);
    signingKey = info?['signing_public_key'] as String?;
    if (signingKey != null && signingKey.isNotEmpty && contact != null) {
      await contactDao.insertContact(
        Contact(
          uid: contact.uid,
          username: contact.username,
          identityPublicKey: contact.identityPublicKey,
          signingPublicKey: signingKey,
          createdAt: contact.createdAt,
        ),
      );
    }
    return signingKey;
  }

  /// Verifies a group payload signature: Ed25519(packetId|text|groupId).
  /// Missing sig = legacy client → accept (rollout compat). Invalid sig →
  /// drop + log (relay/member spoofing attempt). Fetches + caches the
  /// sender's signing key on demand.
  Future<bool> _verifyGroupSender({
    required String senderUid,
    required String packetId,
    required String text,
    required String groupId,
    required String? signature,
  }) async {
    if (signature == null || signature.isEmpty) return true;
    try {
      var contact = await contactDao.getContactByUid(senderUid);
      var signingKey = contact?.signingPublicKey;
      if (signingKey == null || signingKey.isEmpty) {
        final info = await const ApiClient().lookupIdentity(uid: senderUid);
        signingKey = info?['signing_public_key'] as String?;
        if (signingKey != null && signingKey.isNotEmpty && contact != null) {
          await contactDao.insertContact(
            Contact(
              uid: contact.uid,
              username: contact.username,
              identityPublicKey: contact.identityPublicKey,
              signingPublicKey: signingKey,
              createdAt: contact.createdAt,
            ),
          );
        }
      }
      if (signingKey == null || signingKey.isEmpty) return true;
      final engine = SigningEngine();
      final ok = await engine.verifyHex(
        message: '$packetId|$text|$groupId',
        signatureHex: signature,
        publicKeyHex: signingKey,
      );
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Verifies a group CONTROL signature: Ed25519(type|groupId|roster).
  /// Missing key → fetch + cache from directory, then verify.
  Future<bool> _verifyControlSender({
    required String senderUid,
    required String type,
    required String groupId,
    required List<String> memberUids,
    required String? signature,
  }) async {
    if (signature == null || signature.isEmpty) return true;
    try {
      var contact = await contactDao.getContactByUid(senderUid);
      var signingKey = contact?.signingPublicKey;
      if (signingKey == null || signingKey.isEmpty) {
        final info = await const ApiClient().lookupIdentity(uid: senderUid);
        signingKey = info?['signing_public_key'] as String?;
        if (signingKey != null && signingKey.isNotEmpty && contact != null) {
          await contactDao.insertContact(
            Contact(
              uid: contact.uid,
              username: contact.username,
              identityPublicKey: contact.identityPublicKey,
              signingPublicKey: signingKey,
              createdAt: contact.createdAt,
            ),
          );
        }
      }
      if (signingKey == null || signingKey.isEmpty) return true;
      return await SigningEngine().verifyHex(
        message: '$type|$groupId|${memberUids.join(',')}',
        signatureHex: signature,
        publicKeyHex: signingKey,
      );
    } catch (_) {
      return false;
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
        final username =
            (info?['username'] as String?) ?? _fallbackName(senderUid);
        final publicKey = (info?['identity_public_key'] as String?) ?? '';
        await contactDao.insertContact(
          Contact(
            uid: senderUid,
            username: username,
            identityPublicKey: publicKey,
            signingPublicKey: info?['signing_public_key'] as String?,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        // 'contacts' (not 'messages') so live chat notifiers don't all
        // reload their history just because a name resolved.
        bus.fire(RefreshEvent(type: 'contacts'));
      } else if (_isFallbackName(existing.username) ||
          (existing.signingPublicKey?.isEmpty ?? true)) {
        final info = await const ApiClient().lookupIdentity(uid: senderUid);
        final realName = info?['username'] as String?;
        final signingKey = info?['signing_public_key'] as String?;
        if ((realName != null &&
                realName.isNotEmpty &&
                realName != existing.username) ||
            (signingKey != null &&
                signingKey.isNotEmpty &&
                signingKey != existing.signingPublicKey)) {
          await contactDao.insertContact(
            Contact(
              uid: existing.uid,
              username: (realName != null && realName.isNotEmpty)
                  ? realName
                  : existing.username,
              identityPublicKey: existing.identityPublicKey,
              signingPublicKey: (signingKey != null && signingKey.isNotEmpty)
                  ? signingKey
                  : existing.signingPublicKey,
              createdAt: existing.createdAt,
            ),
          );
          bus.fire(RefreshEvent(type: 'contacts'));
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

final messageRouterProvider = Provider.family<MessageRouter, String>((
  ref,
  uid,
) {
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
