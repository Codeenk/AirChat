import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class CryptoPayload {
  final String cipherText;
  final String nonce;
  final String senderEphemeralPublicKey;

  CryptoPayload({
    required this.cipherText,
    required this.nonce,
    required this.senderEphemeralPublicKey,
  });

  Map<String, dynamic> toJson() => {
    'ct': cipherText,
    'n': nonce,
    'epk': senderEphemeralPublicKey,
  };

  factory CryptoPayload.fromJson(Map<String, dynamic> json) => CryptoPayload(
    cipherText: json['ct'] ?? '',
    nonce: json['n'] ?? '',
    senderEphemeralPublicKey: json['epk'] ?? '',
  );

  String encode() => jsonEncode(toJson());

  factory CryptoPayload.decode(String rawJson) =>
      CryptoPayload.fromJson(jsonDecode(rawJson));
}

class SodiumEngine {
  final algorithm = X25519();
  final cipher = Chacha20.poly1305Aead();

  Future<SimpleKeyPair> generateIdentityKeyPair() async {
    return await algorithm.newKeyPair();
  }

  Future<SimplePublicKey> importPublicKey(String base64PublicKey) async {
    final bytes = base64Decode(base64PublicKey);
    return SimplePublicKey(bytes, type: KeyPairType.x25519);
  }

  Future<String> exportPublicKey(SimpleKeyPair keyPair) async {
    final pubKey = await keyPair.extractPublicKey();
    return base64Encode(pubKey.bytes);
  }

  Future<CryptoPayload> encryptMessage({
    required String plainText,
    required SimplePublicKey recipientPublicKey,
    required SimpleKeyPair senderKeyPair,
  }) async {
    // Generate ephemeral key for Forward Secrecy per message
    final ephemeralKeyPair = await algorithm.newKeyPair();
    final sharedSecret = await algorithm.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPublicKey,
    );

    final secretKeyBytes = await sharedSecret.extractBytes();
    final secretKey = SecretKey(secretKeyBytes);

    final nonce = cipher.newNonce();
    final clearBytes = utf8.encode(plainText);

    final secretBox = await cipher.encrypt(
      clearBytes,
      secretKey: secretKey,
      nonce: nonce,
    );

    final ephemeralPub = await ephemeralKeyPair.extractPublicKey();

    return CryptoPayload(
      cipherText: base64Encode(secretBox.concatenation()),
      nonce: base64Encode(nonce),
      senderEphemeralPublicKey: base64Encode(ephemeralPub.bytes),
    );
  }

  Future<String> decryptMessage({
    required CryptoPayload payload,
    required SimpleKeyPair recipientKeyPair,
  }) async {
    final remoteEphemeralKey = SimplePublicKey(
      base64Decode(payload.senderEphemeralPublicKey),
      type: KeyPairType.x25519,
    );

    final sharedSecret = await algorithm.sharedSecretKey(
      keyPair: recipientKeyPair,
      remotePublicKey: remoteEphemeralKey,
    );

    final secretKeyBytes = await sharedSecret.extractBytes();
    final secretKey = SecretKey(secretKeyBytes);
    final concatenated = base64Decode(payload.cipherText);

    final secretBox = SecretBox.fromConcatenation(
      concatenated,
      nonceLength: 12,
      macLength: 16,
    );

    final decryptedBytes = await cipher.decrypt(
      secretBox,
      secretKey: secretKey,
    );
    return utf8.decode(decryptedBytes);
  }

  // ─── SYMMETRIC GROUP ENCRYPTION ───
  // ChaCha20-Poly1305 with a pre-shared groupKey (32 bytes, base64-encoded).
  // No ephemeral keys — all members share the same key.

  /// Encrypts a plaintext using the shared groupKey (ChaCha20-Poly1305).
  /// Returns a simple {ct, n} payload (no epk needed for symmetric).
  Future<CryptoPayload> encryptGroupMessage({
    required String plainText,
    required String groupKeyBase64,
  }) async {
    final keyBytes = base64Decode(groupKeyBase64);
    final secretKey = SecretKey(keyBytes);
    final nonce = cipher.newNonce();
    final clearBytes = utf8.encode(plainText);

    final secretBox = await cipher.encrypt(
      clearBytes,
      secretKey: secretKey,
      nonce: nonce,
    );

    return CryptoPayload(
      cipherText: base64Encode(secretBox.concatenation()),
      nonce: base64Encode(nonce),
      senderEphemeralPublicKey: '', // not used for symmetric
    );
  }

  /// Decrypts a group message using the shared groupKey.
  Future<String> decryptGroupMessage({
    required CryptoPayload payload,
    required String groupKeyBase64,
  }) async {
    final keyBytes = base64Decode(groupKeyBase64);
    final secretKey = SecretKey(keyBytes);
    final concatenated = base64Decode(payload.cipherText);

    final secretBox = SecretBox.fromConcatenation(
      concatenated,
      nonceLength: 12,
      macLength: 16,
    );

    final decryptedBytes = await cipher.decrypt(
      secretBox,
      secretKey: secretKey,
    );
    return utf8.decode(decryptedBytes);
  }
}
