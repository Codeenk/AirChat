import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../crypto/key_store.dart';
import '../crypto/sodium_engine.dart';
import '../database/app_database.dart';
import '../database/daos/contact_dao.dart';
import '../database/daos/message_dao.dart';
import '../network/websocket_client.dart';
import '../../models/message_payload.dart';

/// Sends a quick-reply from the notification action. Works from a background
/// isolate: opens the encrypted DB, resolves the recipient key, encrypts,
/// fires the packet over a short-lived WebSocket, then cleans up.
class QuickReplySender {
  QuickReplySender._();

  static Future<bool> send({
    required String recipientUid,
    required String text,
  }) async {
    if (kIsWeb) return false;
    try {
      final myUid = await KeyStore.getUid();
      final keyPair = await KeyStore.getKeyPair();
      if (myUid == null || keyPair == null) return false;

      final contact = await ContactDao().getContactByUid(recipientUid);
      final pubKey = contact?.identityPublicKey;
      if (pubKey == null || pubKey.isEmpty) return false;

      await AppDatabase.instance; // open (or reuse) encrypted DB

      final engine = SodiumEngine();
      final recipientPub = await engine.importPublicKey(pubKey);
      final payload = await engine.encryptMessage(
        plainText: jsonEncode({'text': text, 'type': 'text'}),
        recipientPublicKey: recipientPub,
        senderKeyPair: keyPair,
      );

      final packetId = DateTime.now().microsecondsSinceEpoch.toString();
      final chatId = _chatId(myUid, recipientUid);
      final now = DateTime.now().millisecondsSinceEpoch;

      await MessageDao().insertMessage(ChatMessage(
        id: packetId,
        chatId: chatId,
        senderUid: myUid,
        recipientUid: recipientUid,
        text: text,
        timestamp: now,
        isMe: true,
        status: 'sending',
      ));

      final ws = WebSocketTunnelClient(uid: myUid);
      ws.sendPacket(
        recipientUid: recipientUid,
        encryptedPayload: payload.encode(),
        packetId: packetId,
      );
      // Give the socket a moment to flush, then tear down this isolate's
      // connection (the main app keeps its own).
      await Future<void>.delayed(const Duration(seconds: 2));
      ws.dispose();

      // Mark delivered so the app never shows an eternal "sending" spinner
      // for this message (the temp isolate can't receive the relay ack).
      await MessageDao().updateMessageStatus(packetId, 'delivered');
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _chatId(String a, String b) {
    final ids = [a, b]..sort();
    return ids.join('_');
  }
}
