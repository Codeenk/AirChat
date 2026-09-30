import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crash/crash_reporter.dart';
import '../core/crypto/key_store.dart';
import '../core/crypto/mls_group_service.dart';
import '../core/crypto/delivery_tag.dart';
import '../core/crypto/ratchet_session.dart';
import '../core/crypto/sealed_sender.dart';
import '../core/crypto/relay_auth.dart';
import '../core/crypto/signing_engine.dart';
import '../core/crypto/sodium_engine.dart';
import '../core/crypto/wire_envelope.dart';
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
import 'crypto_provider.dart';
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
  // Declared before construction so the callbacks below can refer to the
  // client they belong to.
  late final WebSocketTunnelClient client;
  client = WebSocketTunnelClient(
    uid: uid,
    signChallenge: (nonce) => signRelayChallenge(uid, nonce),
    onAuthenticated: () async {
      // Claim our sealed-sender delivery tags on every successful connect.
      //
      // A tag row on the relay is what makes this device reachable at all on the
      // sealed transport, and the claim is deliberately self-healing: it is
      // unauthenticated (a tag confers no privilege) and re-sent on every
      // connect, so a lost row, an expired TTL, or another device racing us for
      // the same tag all resolve on the next connection.
      try {
        await SealedSender.instance.register(
          client,
          fcmToken: await PushService.lastKnownToken(),
        );
      } catch (_) {}
    },
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
      } else if (type == 'sealed_message') {
        _handleSealedMessage(msg);
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
      } else if (type == 'seal_status') {
        // Same vocabulary as `packet_status`, plus the sealed-only failures
        // (an expired or unregistered recipient tag) which mean "could not
        // deliver" and must not leave the bubble spinning forever.
        final packetId = msg['packetId'] as String?;
        final status = msg['status'] as String?;
        final mapped = status == null
            ? null
            : (mapRelayStatus(status) ?? mapSealedFailure(status));
        if (packetId != null && mapped != null) {
          messageDao.updateMessageStatus(packetId, mapped);
          bus.fire(
            RefreshEvent(type: 'status', messageId: packetId, status: mapped),
          );
        }
      } else if (type == 'seal_read') {
        final packetId = msg['packetId'] as String?;
        if (packetId != null) {
          messageDao.updateMessageStatus(packetId, 'read');
          bus.fire(
            RefreshEvent(type: 'status', messageId: packetId, status: 'read'),
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

    if (_outsideReplayWindow(timestamp)) {
      CrashReporter.recordError(
        error: 'replay/out-of-window dropped from $senderUid',
        source: 'replay-guard',
      );
      return;
    }

    try {
      final decrypted = await _decryptDirect(
        senderUid: senderUid,
        encodedPayload: encodedPayload,
      );
      await _processDirectPlaintext(
        senderUid: senderUid,
        packetId: packetId,
        timestamp: timestamp,
        decrypted: decrypted,
      );
    } catch (e) {
      // Decryption failed or message already stored
    }
  }

  /// Handles a **sealed** packet: the relay delivered it without ever knowing
  /// who sent it, so no uid arrives with it in either direction.
  ///
  /// The sender is recovered by decryption, not by asking the relay:
  /// [SealedSender.open] tries the packet against our own sessions, and the
  /// peer whose session opens it *is* the sender, cryptographically. A packet
  /// that opens against nobody is not acked — it stays on the relay until its
  /// TTL rather than being destroyed — because the one thing we know for certain
  /// is that we could not read it yet.
  Future<void> _handleSealedMessage(Map<String, dynamic> msg) async {
    // The tag the relay addressed it to. It is our own tag, not an identity,
    // and it is what the ack has to quote.
    final tag = msg['to'] as String?;
    final packetId = msg['packetId'] as String?;
    final body = msg['body'] as String?;
    final timestamp =
        msg['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    if (tag == null || packetId == null || body == null) return;

    if (_outsideReplayWindow(timestamp)) {
      CrashReporter.recordError(
        error: 'sealed replay/out-of-window dropped for $packetId',
        source: 'replay-guard',
      );
      return;
    }

    SealedInbound? opened;
    try {
      opened = await SealedSender.instance.open(body: body, packetId: packetId);
    } catch (e) {
      CrashReporter.recordError(
        error: 'sealed open failed for $packetId: $e',
        source: 'sealed-receive',
      );
    }
    if (opened == null) return;

    // Where a reply, and every later status, must go. This comes from the
    // peer's *own* authenticated payload — never from the wire. The relay
    // supplies a `reply` field on a legacy-shaped delivery, but it is
    // relay-authored: trusting it would let a hostile relay point our sends at
    // a tag it controls, and it is absent from `sealed_message` anyway, because
    // a client that can open the message already knows the return path.
    final replyTag = _sealedPayloadTag(opened.plaintext);

    try {
      await _processDirectPlaintext(
        senderUid: opened.senderUid,
        packetId: packetId,
        timestamp: timestamp,
        decrypted: opened.plaintext,
        replyTag: replyTag,
      );
    } catch (e) {
      CrashReporter.recordError(
        error: 'sealed payload rejected for $packetId: $e',
        source: 'sealed-receive',
      );
    }

    await SealedSender.instance.rememberPeerTag(opened.senderUid, replyTag);

    // Acknowledged *after* the payload was processed, so a message we could not
    // read is left on the relay rather than destroyed. `tag` is our own address
    // and scopes the delete; [replyTag] only routes the delivery status back to
    // its author, and an offline author simply gets no status — which their
    // client already treats as "still queued".
    SealedSender.instance.ack(
      client: client,
      tag: tag,
      packetId: packetId,
      replyTag: replyTag,
    );
  }

  /// The sender's delivery tag as advertised inside their own encrypted
  /// payload, or null when they use a build that does not send one.
  static String? _sealedPayloadTag(String plaintext) {
    try {
      final decoded = jsonDecode(plaintext);
      if (decoded is! Map) return null;
      return decoded['dt'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Whether a relay timestamp is outside the accepted window: older than the
  /// 24h cache TTL (+1h skew) or more than 5min in the future (clock games /
  /// replay injection). Shared by both transports — a sealed packet is no more
  /// trustworthy than a named one.
  static bool _outsideReplayWindow(int timestamp) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return timestamp < now - 25 * 60 * 60 * 1000 ||
        timestamp > now + 5 * 60 * 1000;
  }

  /// Everything that happens *after* a 1:1 payload has been decrypted — group
  /// controls, sender-signature verification, storage, notifications.
  ///
  /// Shared by the named and sealed transports on purpose: this is where
  /// authenticity is actually decided (the Ed25519 signature over
  /// `packetId|text|chatId`), and a second copy of it would be a second place
  /// for that to silently weaken.
  Future<void> _processDirectPlaintext({
    required String senderUid,
    required String packetId,
    required int timestamp,
    required String decrypted,
    String? replyTag,
  }) async {
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
      final incomingCrypto = decoded['cryptoVersion'] as int?;
      if (gid.isNotEmpty) {
        if (messageType == 'group_kick' &&
            (decoded['kickedUid'] as String? ?? '') == uid) {
          await GroupDao().deleteGroup(gid);
          // Drop the MLS state too: a group this device has left must not
          // keep epoch secrets that would still open its traffic.
          try {
            await MlsGroupService.instance.deleteGroup(gid);
          } catch (_) {}
        } else {
          final wasKick = messageType == 'group_kick';
          // An MLS invite carries a Welcome rather than a key. Join it first
          // so this device holds a leaf in the ratchet tree before any group
          // traffic for it arrives — a message for an epoch we are not in
          // cannot be opened, and there is no second chance to join later.
          final existingGroup = await GroupDao().getGroupById(gid);
          final mlsWelcome = decoded['mlsWelcome'] as String?;
          var mlsJoined = existingGroup != null && existingGroup.usesMls;
          if (!mlsJoined && mlsWelcome != null && mlsWelcome.isNotEmpty) {
            mlsJoined = await _joinMlsGroup(gid, mlsWelcome);
          }
          // If we already have this group locally, preserve the existing groupKey
          // unless the incoming payload carries a new one (key rotation).
          final incomingVersion = decoded['keyVersion'] as int?;
          final carriesKey =
              receivedGroupKey != null && receivedGroupKey.isNotEmpty;
          // Replay guard. The relay is unordered and replayable, so an old
          // key-carrying control can arrive after a newer one. Applying it
          // would restore a superseded group key and silently undo the
          // rotation that revoked a removed member. A generation that is not
          // newer than what we hold is dropped.
          // Unversioned controls (legacy clients) are still accepted so the
          // rollout does not break groups that predate versioning.
          if (carriesKey &&
              !acceptsControlVersion(
                localVersion: existingGroup?.keyVersion ?? 0,
                incomingVersion: incomingVersion,
              )) {
            CrashReporter.recordError(
              error: 'stale key-carrying group control dropped for $gid',
              source: 'group-version',
            );
            return;
          }
          final effectiveKey = receivedGroupKey ?? existingGroup?.groupKey;
          await GroupDao().insertGroup(
            Group(
              id: gid,
              name: gname,
              memberUids: memberUids.isEmpty ? [uid, senderUid] : memberUids,
              createdAt: timestamp,
              groupKey: effectiveKey,
              keyVersion: incomingVersion ?? existingGroup?.keyVersion ?? 0,
              // Preserve this group's scheme. A control that does not name
              // one (a legacy client) must not flip a group either way: only
              // a Welcome moves a group onto MLS, and only the group's own
              // creator decides that.
              cryptoVersion: mlsJoined
                  ? GroupCrypto.mls
                  : (incomingCrypto ??
                        existingGroup?.cryptoVersion ??
                        GroupCrypto.legacySharedKey),
            ),
          );
          // A kick changed the roster. The elected survivor then revokes the
          // departed member: an MLS commit that removes them from the tree,
          // or a shared-key rotation for a legacy group. See
          // groupRekeyWatcherProvider.
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
      replyTag: replyTag,
    );

    await messageDao.insertMessage(message);

    if (isGroup) {
      if (MessageRouter.openChatId != chatId) {
        await GroupDao().incrementUnread(chatId);
      }
      bus.fire(RefreshEvent(type: 'messages', chatId: chatId));
      if (!_isOpenChatVisible(chatId)) {
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
        await _sendReadReceipt(
          packetId: packetId,
          senderUid: senderUid,
          replyTag: replyTag,
        );
      }

      if (!_isOpenChatVisible(chatId)) {
        await NotificationService.instance.showMessageNotification(
          title: contactName,
          body: text.isEmpty ? '📎 $messageType' : text,
          senderUid: senderUid,
        );
      }
    }

    // Background directory resolution — never blocks message delivery.
    _resolveContactInBackground(senderUid);
  }

  /// Tells the author we read their message, on whichever transport their
  /// message arrived by.
  ///
  /// A message that arrived sealed has no sender uid to name, so its receipt
  /// travels back along the tag its author quoted. The tag *we* quote is simply
  /// one we currently own: the relay only forwards to the socket that registered
  /// it, and by now the packet has been acked, so there is nothing left to
  /// delete — the receipt is purely a notification.
  Future<void> _sendReadReceipt({
    required String packetId,
    required String senderUid,
    String? replyTag,
  }) async {
    if (replyTag == null || replyTag.isEmpty) {
      client.sendReadReceipt(packetId: packetId, senderUid: senderUid);
      return;
    }
    final ourTag = await DeliveryTagRegistry.instance.currentTag();
    if (ourTag == null) return;
    SealedSender.instance.receipt(
      client: client,
      tag: ourTag,
      packetId: packetId,
      replyTag: replyTag,
    );
  }

  /// Decrypts a 1:1 payload, on the ratchet when the envelope says so.
  ///
  /// A v2 envelope is never retried on the legacy path. The sender chose the
  /// ratchet deliberately, so a failure here is a real failure — and falling
  /// back would let anyone who can corrupt one field force the message onto the
  /// weaker scheme.
  Future<String> _decryptDirect({
    required String senderUid,
    required String encodedPayload,
  }) async {
    final envelope = WireEnvelope.tryDecode(encodedPayload);
    if (envelope != null && envelope.kind == WireEnvelope.kindSignal) {
      final plaintext = await RatchetSession.instance.decrypt(
        senderUid,
        envelope,
      );
      // The chat is now demonstrably on the ratchet, so record it: replies must
      // use the same scheme, and this is the only evidence we have that the
      // peer actually speaks it.
      await chatDao.setCryptoVersion(
        _chatId(uid, senderUid),
        ChatCrypto.doubleRatchet,
      );
      return plaintext;
    }

    final keyPair = await KeyStore.getKeyPair();
    if (keyPair == null) throw StateError('no identity key available');
    return engine.decryptMessage(
      payload: CryptoPayload.decode(encodedPayload),
      recipientKeyPair: keyPair,
    );
  }

  /// Joins an MLS group from a Welcome, reporting whether it worked.
  ///
  /// A failure leaves the group on the legacy path rather than half-joined:
  /// `joinFromWelcome` validates the group id and ciphersuite before it commits
  /// anything, so a forged or mismatched Welcome cannot corrupt local state.
  Future<bool> _joinMlsGroup(String groupId, String welcomeBase64) async {
    try {
      await MlsGroupService.instance.joinFromWelcome(
        expectedGroupId: groupId,
        welcome: base64Decode(welcomeBase64),
      );
      return true;
    } catch (e) {
      CrashReporter.recordError(
        error: 'MLS welcome join failed for $groupId: $e',
        source: 'mls-join',
      );
      return false;
    }
  }

  /// Handles a group_packet pushed by the relay — either an MLS message, or a
  /// ciphertext under the legacy shared groupKey.
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

    final localGroup = await GroupDao().getGroupById(groupId);
    if (localGroup == null) return; // group not known locally — ignore

    // MLS authenticates the sender cryptographically: the uid comes from the
    // ratchet-tree leaf that produced the message, so it cannot be claimed by
    // anyone outside the group and it cannot be forged by the relay. The legacy
    // path has no such binding, so there the relay-reported uid is checked
    // against the roster instead.
    var senderUidResolved = senderUid;
    final Map<String, dynamic> decoded;
    try {
      if (localGroup.usesMls) {
        final envelope = WireEnvelope.tryDecode(encodedPayload);
        if (envelope == null || envelope.kind != WireEnvelope.kindMls) {
          // Legacy ciphertext in an MLS group: unreadable and not ours.
          return;
        }
        final result = await MlsGroupService.instance.decrypt(
          groupId: groupId,
          message: envelope.ciphertext,
        );
        senderUidResolved = result.senderUid ?? senderUid;

        if (result.evicted) {
          // This commit removed *us*. Drop the group and its MLS state: the
          // epoch secrets this device holds no longer derive anything the group
          // uses, and keeping the thread would show a conversation it can
          // silently never read again.
          await GroupDao().deleteGroup(groupId);
          try {
            await MlsGroupService.instance.deleteGroup(groupId);
          } catch (_) {}
          bus.fire(RefreshEvent(type: 'messages', chatId: groupId));
          return;
        }

        if (result.appliedCommit) {
          // A commit advanced the epoch — a member was added or removed. The
          // roster in the tree is authoritative, so adopt it.
          final members = await MlsGroupService.instance.members(groupId);
          if (members.isNotEmpty) {
            await GroupDao().updateMembers(groupId, members);
          }
          bus.fire(RefreshEvent(type: 'messages', chatId: groupId));
        }

        if (result.plaintext == null) {
          // A control message (commit/proposal) with nothing to display. Ack it
          // so the relay drops its cached copy.
          client.ackGroupPacket(packetId: packetId, groupId: groupId);
          return;
        }
        decoded = jsonDecode(result.plaintext!) as Map<String, dynamic>;
      } else {
        if (!localGroup.memberUids.contains(senderUid)) {
          return; // sender was removed
        }
        final groupKey = localGroup.groupKey;
        if (groupKey == null || groupKey.isEmpty) return; // no key available
        final cryptoPayload = CryptoPayload.decode(encodedPayload);
        final decrypted = await engine.decryptGroupMessage(
          payload: cryptoPayload,
          groupKeyBase64: groupKey,
        );
        decoded = jsonDecode(decrypted) as Map<String, dynamic>;
      }

      final text = decoded['text'] ?? '';
      final messageType = decoded['type'] ?? 'text';
      final mediaKey = decoded['mediaKey'];
      final secretKeyHex = decoded['secretKeyHex'];
      final nonceHex = decoded['nonceHex'];
      final replyTo = (decoded['replyTo'] as Map<String, dynamic>?) ?? const {};

      // Verify sender signature (drops relay/member spoofing).
      final sigOk = await _verifyGroupSender(
        senderUid: senderUidResolved,
        packetId: packetId,
        text: text,
        groupId: groupId,
        signature: decoded['sig'] as String?,
      );
      if (!sigOk) {
        CrashReporter.recordError(
          error: 'group sig invalid from $senderUidResolved in $groupId',
          source: 'group-verify',
        );
        return;
      }

      // Resolve sender name: prefer the name in the payload, then relay, then contact.
      String contactName =
          decoded['senderName'] as String? ?? senderNameFromRelay;
      if (contactName.isEmpty) {
        final existing = await contactDao.getContactByUid(senderUidResolved);
        if (existing != null && !_isFallbackName(existing.username)) {
          contactName = existing.username;
        } else {
          contactName = _fallbackName(senderUid);
        }
      }

      final message = ChatMessage(
        id: packetId,
        chatId: groupId,
        senderUid: senderUidResolved,
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

      if (!_isOpenChatVisible(groupId)) {
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

  /// True only when the user is actively looking at [chatId], so a
  /// notification for it would be redundant. Notifications for every OTHER
  /// conversation still fire, even while a chat screen is open — otherwise a
  /// message from a second contact or group would be silently swallowed.
  bool _isOpenChatVisible(String chatId) =>
      NotificationService.isAppForeground && MessageRouter.openChatId == chatId;

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

  // Publish this device's key material at startup: an MLS KeyPackage so a peer
  // can add it to a group while it is offline, and a libsignal prekey bundle so
  // a peer can open a Double Ratchet session with it.
  ref.watch(keyPublicationProvider);

  // Idempotent start — safe even if provider is rebuilt (won't duplicate
  // WebSocket connections or stream listeners).
  router.start();

  // Prevent this provider from being disposed on last listener removal.
  // The MessageRouter owns a WebSocket connection that must persist for
  // the app lifetime.
  ref.keepAlive();

  return router;
});
