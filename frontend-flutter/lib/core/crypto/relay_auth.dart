import '../crypto/key_store.dart';
import '../crypto/signing_engine.dart';

/// Signs the relay auth challenge: Ed25519(nonce + uid) with the identity
/// signing key. Pure Dart + secure storage — works in the main isolate AND
/// the FCM background isolate (no plugins needed).
Future<String?> signRelayChallenge(String uid, String nonce) async {
  try {
    final kp = await KeyStore.getSigningKeyPair();
    if (kp == null) return null;
    return await SigningEngine().signHex('$nonce$uid', kp);
  } catch (_) {
    return null;
  }
}
