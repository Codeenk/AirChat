import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../crash/crash_reporter.dart';
import '../crypto/key_store.dart';
import '../crypto/relay_auth.dart';
import '../crypto/signing_engine.dart';
import '../crypto/sodium_engine.dart';
import '../database/app_database.dart';
import '../database/daos/contact_dao.dart';
import '../database/daos/message_dao.dart';
import '../network/message_status.dart';
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

      final packetId = DateTime.now().microsecondsSinceEpoch.toString();
      final chatId = _chatId(myUid, recipientUid);

      // Sign so the recipient can verify authenticity (same scheme as the
      // main isolate: Ed25519 over packetId|text|chatId).
      String sig = '';
      try {
        final signingKp = await KeyStore.getSigningKeyPair();
        if (signingKp != null) {
          sig = await SigningEngine().signHex(
            '$packetId|$text|$chatId',
            signingKp,
          );
        }
      } catch (_) {}

      final payload = await engine.encryptMessage(
        plainText: jsonEncode({
          'text': text,
          'type': 'text',
          if (sig.isNotEmpty) 'sig': sig,
        }),
        recipientPublicKey: recipientPub,
        senderKeyPair: keyPair,
      );

      final now = DateTime.now().millisecondsSinceEpoch;

      await MessageDao().insertMessage(
        ChatMessage(
          id: packetId,
          chatId: chatId,
          senderUid: myUid,
          recipientUid: recipientUid,
          text: text,
          timestamp: now,
          isMe: true,
          status: 'sending',
        ),
      );

      // The relay requires a signed challenge; without `signChallenge` the
      // socket never authenticates and the packet is silently dropped.
      final ws = WebSocketTunnelClient(
        uid: myUid,
        signChallenge: (nonce) => signRelayChallenge(myUid, nonce),
      );

      final statusCompleter = Completer<String?>();
      final sub = ws.messageStream.listen((m) {
        if (m['type'] == 'packet_status' && m['packetId'] == packetId) {
          final mapped = mapRelayStatus(m['status'] as String? ?? '');
          if (!statusCompleter.isCompleted) statusCompleter.complete(mapped);
        }
      });

      ws.sendPacket(
        recipientUid: recipientUid,
        encryptedPayload: payload.encode(),
        packetId: packetId,
      );

      final relayed = await statusCompleter.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => null,
      );

      await sub.cancel();
      ws.dispose();

      if (relayed != null) {
        // Reflect the relay's truthful status (sent/delivered) — never fake it.
        await MessageDao().updateMessageStatus(packetId, relayed);
        return true;
      }
      // No ack: leave it as 'sending' so the main app retries on next launch.
      await MessageDao().updateMessageStatus(packetId, 'sending');
      return false;
    } catch (e, st) {
      CrashReporter.recordError(
        error: e,
        stackTrace: st,
        source: 'quick-reply',
      );
      return false;
    }
  }

  static String _chatId(String a, String b) {
    final ids = [a, b]..sort();
    return ids.join('_');
  }
}
