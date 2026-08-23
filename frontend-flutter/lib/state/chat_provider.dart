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

  ChatStateNotifier(this.ref, this.activeChatId) : super([]) {
    _loadMessages();
    _subscribeToRefreshBus();
    ref.onDispose(() => _busSub?.cancel());
  }

  /// Live updates: reload on new messages for this chat, patch statuses in-place.
  void _subscribeToRefreshBus() {
    _busSub = ref.read(refreshBusProvider).stream.listen(_onRefreshEvent);
  }

  void _onRefreshEvent(RefreshEvent event) {
    if (event.type == 'messages') {
      // New message(s) stored — reload if for this chat (null = any chat).
      if (event.chatId == null || event.chatId == activeChatId) {
        _loadMessages();
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

  Future<void> _loadMessages() async {
    final messageDao = ref.read(messageDaoProvider);
    final messages = await messageDao.getMessagesForChat(activeChatId);
    if (!mounted) return;
    state = messages;
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
final chatThreadsProvider = StreamProvider.autoDispose<List<ChatThread>>((ref) async* {
  final chatDao = ref.watch(chatDaoProvider);
  yield await chatDao.getAllChats();

  await for (final _ in ref.watch(refreshBusProvider).stream) {
    yield await chatDao.getAllChats();
  }
});
