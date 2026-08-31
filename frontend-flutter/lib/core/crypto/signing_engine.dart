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

  String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
