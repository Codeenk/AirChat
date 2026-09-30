import 'dart:convert';

import '../database/daos/contact_dao.dart';
import '../network/api_client.dart';
import 'key_store.dart';
import 'ratchet_session.dart';
import 'sodium_engine.dart';

/// Encrypts a payload for one peer, preferring an established Double Ratchet
/// session and falling back to the legacy X25519 envelope.
///
/// This is for the paths that do **not** own a chat's scheme — retries from a
/// background isolate, a quick reply from a notification, group control
/// messages. It only rides the ratchet when a session already exists, so it can
/// never pull a peer onto a protocol they have not agreed to; but when a session
/// *does* exist it must use it, because sending a legacy envelope into a ratchet
/// conversation would silently drop that one message back to the scheme with no
/// forward secrecy.
///
/// Returns null when the peer has no usable public key, which the callers treat
/// as "cannot deliver".
Future<String?> encryptToOneToOne(String peerUid, String plaintext) async {
  try {
    final session = RatchetSession.instance;
    if (await session.hasSession(peerUid)) {
      return (await session.encrypt(peerUid, plaintext)).encode();
    }
  } catch (_) {
    // Fall through to the legacy envelope rather than dropping the message.
  }

  try {
    final publicKey = await peerIdentityKey(peerUid);
    if (publicKey == null || publicKey.isEmpty) return null;
    final keyPair = await KeyStore.getKeyPair();
    if (keyPair == null) return null;
    final engine = SodiumEngine();
    final recipient = await engine.importPublicKey(publicKey);
    return (await engine.encryptMessage(
      plainText: plaintext,
      recipientPublicKey: recipient,
      senderKeyPair: keyPair,
    )).encode();
  } catch (_) {
    return null;
  }
}

/// A peer's X25519 identity key, from the local contact cache or, failing
/// that, the directory.
///
/// The fallback matters for messages that are *not* part of a chat's history —
/// an MLS Welcome, a group invite, a notification quick reply. Those can be the
/// first thing this device ever sends to that uid, and needing a cached contact
/// row would make them fail silently against a peer the user has never opened a
/// chat with.
Future<String?> peerIdentityKey(String peerUid) async {
  try {
    final contact = await ContactDao().getContactByUid(peerUid);
    final local = contact?.identityPublicKey;
    if (local != null && local.isNotEmpty) return local;
  } catch (_) {}
  try {
    final info = await const ApiClient().lookupIdentity(uid: peerUid);
    final remote = info?['identity_public_key'] as String?;
    if (remote != null && remote.isNotEmpty) return remote;
  } catch (_) {}
  return null;
}

/// Builds the signed plaintext body shared by every 1:1 send path.
///
/// One place to build it means one place where the field set (media keys, the
/// quoted reply, the sender signature) can drift out of sync — the retry path
/// previously sent a bare `{text,type}` and corrupted media messages.
String buildDirectPayload({
  required String packetId,
  required String chatId,
  required String text,
  required String type,
  String? mediaKey,
  String? secretKeyHex,
  String? nonceHex,
  String? sig,
  Map<String, dynamic>? replyTo,
}) {
  return jsonEncode({
    'text': text,
    'type': type,
    if (mediaKey != null) 'mediaKey': mediaKey,
    if (secretKeyHex != null) 'secretKeyHex': secretKeyHex,
    if (nonceHex != null) 'nonceHex': nonceHex,
    if (sig != null && sig.isNotEmpty) 'sig': sig,
    if (replyTo != null) 'replyTo': replyTo,
  });
}
