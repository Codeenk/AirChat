import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'sodium_engine.dart';

class KeyStore {
  static const _storage = FlutterSecureStorage();
  static const _keyUid = 'airchat_user_uid';
  static const _keyUsername = 'airchat_user_username';
  static const _keyPrivateKey = 'airchat_private_key';
  static const _keyPublicKey = 'airchat_public_key';
  static const _keyDatabaseMasterKey = 'airchat_db_master_key';
  static const _keySigningPrivateKey = 'airchat_signing_private_key';
  static const _keySigningPublicKey = 'airchat_signing_public_key';
  static const _keySigningSignature = 'airchat_signing_signature';

  static final SodiumEngine _engine = SodiumEngine();

  static Future<String> getOrCreateDatabaseMasterKey() async {
    try {
      String? masterKey = await _storage.read(key: _keyDatabaseMasterKey);
      if (masterKey == null) {
        final keyBytes = _engine.cipher.newNonce();
        masterKey = base64Encode(keyBytes);
        await _storage.write(key: _keyDatabaseMasterKey, value: masterKey);
      }
      return masterKey;
    } catch (e) {
      try {
        await _storage.deleteAll();
      } catch (_) {}
      final keyBytes = _engine.cipher.newNonce();
      final masterKey = base64Encode(keyBytes);
      try {
        await _storage.write(key: _keyDatabaseMasterKey, value: masterKey);
      } catch (_) {}
      return masterKey;
    }
  }

  static Future<String?> _safeRead(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveUserIdentity({
    required String uid,
    required String username,
    required SimpleKeyPair keyPair,
    String? signingPublicKeyHex,
    String? signingSignatureHex,
  }) async {
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final pubKey = await keyPair.extractPublicKey();

    await _storage.write(key: _keyUid, value: uid);
    await _storage.write(key: _keyUsername, value: username);
    await _storage.write(key: _keyPrivateKey, value: base64Encode(privateKeyBytes));
    await _storage.write(key: _keyPublicKey, value: base64Encode(pubKey.bytes));
    if (signingPublicKeyHex != null) {
      await _storage.write(key: _keySigningPublicKey, value: signingPublicKeyHex);
    }
    if (signingSignatureHex != null) {
      await _storage.write(key: _keySigningSignature, value: signingSignatureHex);
    }
  }

  static Future<String?> getUid() async => await _safeRead(_keyUid);
  static Future<String?> getUsername() async => await _safeRead(_keyUsername);
  static Future<void> setUsername(String username) async {
    try {
      await _storage.write(key: _keyUsername, value: username);
    } catch (_) {}
  }
  static Future<String?> getPublicKey() async => await _safeRead(_keyPublicKey);
  static Future<String?> getSigningPublicKey() async =>
      await _safeRead(_keySigningPublicKey);
  static Future<String?> getSigningSignature() async =>
      await _safeRead(_keySigningSignature);

  static Future<SimpleKeyPair?> getKeyPair() async {
    final privateKeyBase64 = await _safeRead(_keyPrivateKey);
    final publicKeyBase64 = await _safeRead(_keyPublicKey);
    if (privateKeyBase64 == null || publicKeyBase64 == null) return null;
    try {
      final privateBytes = base64Decode(privateKeyBase64);
      final publicBytes = base64Decode(publicKeyBase64);
      return SimpleKeyPairData(
        privateBytes,
        publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<SimpleKeyPair?> getSigningKeyPair() async {
    final privateKeyHex = await _safeRead(_keySigningPrivateKey);
    final publicKeyHex = await _safeRead(_keySigningPublicKey);
    if (privateKeyHex == null || publicKeyHex == null) return null;
    try {
      final privateBytes = _hexToBytes(privateKeyHex);
      final publicBytes = _hexToBytes(publicKeyHex);
      return SimpleKeyPairData(
        privateBytes,
        publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveSigningKeyPair(SimpleKeyPair keyPair) async {
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final pubKey = await keyPair.extractPublicKey();

    await _storage.write(key: _keySigningPrivateKey, value: _bytesToHex(privateKeyBytes));
    await _storage.write(key: _keySigningPublicKey, value: _bytesToHex(pubKey.bytes));
  }

  static Future<bool> hasIdentity() async {
    final uid = await getUid();
    final pubKey = await getPublicKey();
    return uid != null && pubKey != null;
  }

  static List<int> _hexToBytes(String hex) {
    final cleanHex = hex.startsWith('0x') ? hex.substring(2) : hex;
    final bytes = <int>[];
    for (int i = 0; i < cleanHex.length; i += 2) {
      bytes.add(int.parse(cleanHex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  static String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
