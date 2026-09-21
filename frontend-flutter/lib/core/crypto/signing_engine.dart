import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class SigningEngine {
  final algorithm = Ed25519();

  Future<SimpleKeyPair> generateSigningKeyPair() async {
    return await algorithm.newKeyPair();
  }

  Future<String> exportSigningPublicKeyHex(SimpleKeyPair keyPair) async {
    final pubKey = await keyPair.extractPublicKey();
    return _bytesToHex(pubKey.bytes);
  }

  Future<String> signHex(String message, SimpleKeyPair keyPair) async {
    final signature = await algorithm.sign(
      utf8.encode(message),
      keyPair: keyPair,
    );
    return _bytesToHex(signature.bytes);
  }

  /// Verifies a hex signature over a UTF-8 message with a hex public key.
  Future<bool> verifyHex({
    required String message,
    required String signatureHex,
    required String publicKeyHex,
  }) async {
    try {
      final sigBytes = _hexToBytes(signatureHex);
      final pubBytes = _hexToBytes(publicKeyHex);
      final publicKey = SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
      final signature = Signature(sigBytes, publicKey: publicKey);
      return await algorithm.verify(
        utf8.encode(message),
        signature: signature,
      );
    } catch (_) {
      return false;
    }
  }

  String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  List<int> _hexToBytes(String hex) {
    final cleanHex = hex.startsWith('0x') ? hex.substring(2) : hex;
    final bytes = <int>[];
    for (int i = 0; i < cleanHex.length; i += 2) {
      bytes.add(int.parse(cleanHex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }
}
