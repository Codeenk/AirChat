import 'dart:convert';
import 'dart:async';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/crypto/key_store.dart';
import '../models/chat_thread.dart';
import '../models/message_payload.dart';
import 'connection_provider.dart';
import 'refresh_bus.dart';

const _sendAckTimeout = Duration(seconds: 12);

String buildChatId(String uid1, String uid2) {
  final ids = [uid1, uid2]..sort();
  return ids.join('_');
}

class ChatStateNotifier extends StateNotifier<List<ChatMessage>> {
  final Ref ref;
  final String activeChatId;
  StreamSubscription<RefreshEvent>? _busSub;
  int _offset = 0;
  bool _hasMore = true;
  static const int _pageSize = 50;

  ChatStateNotifier(this.ref, this.activeChatId) : super([]) {
    _loadInitialMessages();
    _subscribeToRefreshBus();
    ref.onDispose(() => _busSub?.cancel());
  }

  bool get hasMore => _hasMore;

  /// Live updates: reload on new messages for this chat, patch statuses in-place.
  void _subscribeToRefreshBus() {
    _busSub = ref.read(refreshBusProvider).stream.listen(_onRefreshEvent);
  }

  void _onRefreshEvent(RefreshEvent event) {
    if (event.type == 'messages') {
      // New message(s) stored — reload if for this chat (null = any chat).
      if (event.chatId == null || event.chatId == activeChatId) {
        _reloadMessages();
      }
    } else if (event.type == 'status' && event.messageId != null) {
      // Patch status in-place — instant tick update, then persist.
      final updated = <ChatMessage>[];
      var changed = false;
      for (final m in state) {
        if (m.id == event.messageId && m.status != event.status) {
          updated.add(m.copyWith(status: event.status));
          changed = true;
        } else {
          updated.add(m);
        }
      }
      if (changed) {
        state = updated;
        ref
            .read(messageDaoProvider)
            .updateMessageStatus(event.messageId!, event.status!);
      }
    }
  }

  /// Initial load: fetch the latest page from the tail of the table.
  Future<void> _loadInitialMessages() async {
    final messageDao = ref.read(messageDaoProvider);
    final totalCount = await messageDao.getMessageCount(activeChatId);
    _offset = (totalCount - _pageSize).clamp(0, totalCount);
    _hasMore = _offset > 0;

    final messages = await messageDao.getMessagesForChat(
      activeChatId,
      limit: _pageSize,
      offset: _offset,
    );
    if (!mounted) return;
    state = messages;
  }

  /// On new message events: reload the latest page (preserves scroll position
  /// if user is near the bottom).
  Future<void> _reloadMessages() async {
    final messageDao = ref.read(messageDaoProvider);
    final totalCount = await messageDao.getMessageCount(activeChatId);
    _offset = (totalCount - _pageSize).clamp(0, totalCount);
    _hasMore = _offset > 0;

    final messages = await messageDao.getMessagesForChat(
      activeChatId,
      limit: _pageSize,
      offset: _offset,
    );
    if (!mounted) return;
    state = messages;
  }

  /// Load older messages when user scrolls to top.
  Future<void> loadMore() async {
    if (!_hasMore) return;
    final messageDao = ref.read(messageDaoProvider);
    final newOffset = _offset - _pageSize;
    final offset = newOffset < 0 ? 0 : newOffset;

    final older = await messageDao.getMessagesForChat(
      activeChatId,
      limit: _pageSize,
      offset: offset,
    );
    if (!mounted) return;
    _offset = offset;
    _hasMore = _offset > 0;
    state = [...older, ...state];
  }

  /// If no server ack (relayed/queued) arrives in time, surface the failure
  /// instead of leaving a clock icon forever. Tap-to-retry supported.
  void _scheduleSendTimeout(String packetId) {
    Timer(_sendAckTimeout, () async {
      final idx = state.indexWhere((m) => m.id == packetId);
      if (idx == -1) return;
      if (state[idx].status != 'sending') return; // acked meanwhile

      final updated = [...state];
      updated[idx] = updated[idx].copyWith(status: 'failed');
      state = updated;
      await ref
          .read(messageDaoProvider)
          .updateMessageStatus(packetId, 'failed');
    });
  }

  /// Marks all incoming 'delivered' messages in this chat as read: sends
  /// read receipts, updates the DB and patches local state. Called when the
  /// chat screen is opened (or new messages arrive while it's open).
  Future<void> markIncomingAsRead() async {
    final senderUid = await KeyStore.getUid();
    if (senderUid == null || senderUid.isEmpty) return;

    final ws = ref.read(websocketClientProvider(senderUid));
    final dao = ref.read(messageDaoProvider);
    final updated = <ChatMessage>[];
    var changed = false;

    for (final m in state) {
      if (!m.isMe && m.status == 'delivered') {
        ws.sendReadReceipt(packetId: m.id, senderUid: m.senderUid);
        await dao.updateMessageStatus(m.id, 'read');
        updated.add(m.copyWith(status: 'read'));
        changed = true;
      } else {
        updated.add(m);
      }
    }
    if (changed) state = updated;
  }

  /// Re-attempt delivery of a failed message (same id → replaces DB row).
  Future<void> resendMessage(ChatMessage msg,
      {required String recipientPublicKeyBase64}) async {
    final senderUid = await KeyStore.getUid() ?? '';
    final senderKeyPair = await KeyStore.getKeyPair();
    if (senderKeyPair == null) return;

    // flip to sending locally + persist
    final idx = state.indexWhere((m) => m.id == msg.id);
    if (idx == -1) return;
    final updated = [...state];
    updated[idx] = msg.copyWith(status: 'sending');
    state = updated;
    await ref
        .read(messageDaoProvider)
        .updateMessageStatus(msg.id, 'sending');

    try {
      final encryptedPayload = await _encryptMessagePayload(
        text: msg.text,
        type: msg.type,
        mediaKey: msg.mediaKey,
        secretKeyHex: msg.secretKeyHex,
        nonceHex: msg.nonceHex,
        replyTo: msg.hasReply ? msg : null,
        recipientPublicKeyBase64: recipientPublicKeyBase64,
        senderKeyPair: senderKeyPair,
      );
      final ws = ref.read(websocketClientProvider(senderUid));
      ws.sendPacket(
        recipientUid: msg.recipientUid,
        encryptedPayload: encryptedPayload,
        packetId: msg.id,
      );
    } catch (_) {}
    _scheduleSendTimeout(msg.id);
  }

  Future<String> _encryptMessagePayload({
    required String text,
    required String type,
    String? mediaKey,
    String? secretKeyHex,
    String? nonceHex,
    ChatMessage? replyTo,
    required String recipientPublicKeyBase64,
    required SimpleKeyPair senderKeyPair,
  }) async {
    final engine = ref.read(sodiumEngineProvider);
    final recipientPubKey = await engine.importPublicKey(recipientPublicKeyBase64);

    final messageJson = jsonEncode({
      'text': text,
      'type': type,
      if (mediaKey != null) 'mediaKey': mediaKey,
      if (secretKeyHex != null) 'secretKeyHex': secretKeyHex,
      if (nonceHex != null) 'nonceHex': nonceHex,
      if (replyTo != null)
        'replyTo': {
          'id': replyTo.id,
          'text': replyTo.text,
          'type': replyTo.type,
          'isMe': replyTo.isMe,
        },
    });

    final cryptoPayload = await engine.encryptMessage(
      plainText: messageJson,
      recipientPublicKey: recipientPubKey,
      senderKeyPair: senderKeyPair,
    );

    return cryptoPayload.encode();
  }

  Future<void> sendTextMessage({
    required String recipientUid,
    required String recipientPublicKeyBase64,
    required String text,
    ChatMessage? replyTo,
  }) async {
    final senderUid = await KeyStore.getUid() ?? '';
    final senderKeyPair = await KeyStore.getKeyPair();
    if (senderKeyPair == null) return;

    final packetId = const Uuid().v4();
    final message = ChatMessage(
      id: packetId,
      chatId: activeChatId,
      senderUid: senderUid,
      recipientUid: recipientUid,
      text: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMe: true,
      status: 'sending',
      replyToId: replyTo?.id,
      replyText: replyTo?.text ?? '',
      replyType: replyTo?.type ?? 'text',
      replyIsMe: replyTo?.isMe,
    );

    await ref.read(messageDaoProvider).insertMessage(message);
    state = [...state, message];

    await ref.read(chatDaoProvider).insertOrUpdateChat(ChatThread(
      id: activeChatId,
      contactUid: recipientUid,
      lastMessage: text,
      lastMessageTime: message.timestamp,
    ));

    // Refresh home list preview immediately (outgoing)
    ref.read(refreshBusProvider)
        .fire(RefreshEvent(type: 'messages', chatId: activeChatId));

    final encryptedPayload = await _encryptMessagePayload(
      text: text,
      type: 'text',
      replyTo: replyTo,
      recipientPublicKeyBase64: recipientPublicKeyBase64,
      senderKeyPair: senderKeyPair,
    );

    final ws = ref.read(websocketClientProvider(senderUid));
    ws.sendPacket(
      recipientUid: recipientUid,
      encryptedPayload: encryptedPayload,
      packetId: packetId,
    );
    _scheduleSendTimeout(packetId);
  }

  Future<void> sendMessage({
    required String recipientUid,
    required String recipientPublicKeyBase64,
    required String text,
    required String type,
    String? mediaKey,
    String? secretKeyHex,
    String? nonceHex,
    ChatMessage? replyTo,
  }) async {
    final senderUid = await KeyStore.getUid() ?? '';
    final senderKeyPair = await KeyStore.getKeyPair();
    if (senderKeyPair == null) return;

    final packetId = const Uuid().v4();
    final message = ChatMessage(
      id: packetId,
      chatId: activeChatId,
      senderUid: senderUid,
      recipientUid: recipientUid,
      text: text,
      mediaKey: mediaKey,
      secretKeyHex: secretKeyHex,
      nonceHex: nonceHex,
      type: type,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMe: true,
      status: 'sending',
      replyToId: replyTo?.id,
      replyText: replyTo?.text ?? '',
      replyType: replyTo?.type ?? 'text',
      replyIsMe: replyTo?.isMe,
    );

    await ref.read(messageDaoProvider).insertMessage(message);
    state = [...state, message];

    await ref.read(chatDaoProvider).insertOrUpdateChat(ChatThread(
      id: activeChatId,
      contactUid: recipientUid,
      lastMessage: text,
      lastMessageTime: message.timestamp,
    ));

    // Refresh home list preview immediately (outgoing)
    ref.read(refreshBusProvider)
        .fire(RefreshEvent(type: 'messages', chatId: activeChatId));

    final encryptedPayload = await _encryptMessagePayload(
      text: text,
      type: type,
      mediaKey: mediaKey,
      secretKeyHex: secretKeyHex,
      nonceHex: nonceHex,
      replyTo: replyTo,
      recipientPublicKeyBase64: recipientPublicKeyBase64,
      senderKeyPair: senderKeyPair,
    );

    final ws = ref.read(websocketClientProvider(senderUid));
    ws.sendPacket(
      recipientUid: recipientUid,
      encryptedPayload: encryptedPayload,
      packetId: packetId,
    );
    _scheduleSendTimeout(packetId);
  }
}

final activeChatMessagesProvider =
    StateNotifierProvider.family<ChatStateNotifier, List<ChatMessage>, String>(
        (ref, chatId) {
  return ChatStateNotifier(ref, chatId);
});

/// Reactive home list: initial load, then re-emits on every bus event
/// (new incoming message, status change) so previews/timestamps update live.
/// Uses a single JOIN query to embed contact usernames — no N+1 queries.
final chatThreadsProvider = StreamProvider.autoDispose<List<ChatThread>>((ref) async* {
  final chatDao = ref.watch(chatDaoProvider);
  yield await chatDao.getAllChatsWithContacts();

  await for (final _ in ref.watch(refreshBusProvider).stream) {
    yield await chatDao.getAllChatsWithContacts();
  }
});
