import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

class EncryptedMediaResult {
  final String fileKey;
  final String secretKeyHex;
  final String nonceHex;

  EncryptedMediaResult({
    required this.fileKey,
    required this.secretKeyHex,
    required this.nonceHex,
  });
}

class MediaPipeline {
  static final cipher = Chacha20.poly1305Aead();

  /// Encrypt raw bytes client-side and stream to ephemeral KV storage.
  /// Server never sees keys or plaintext — blobs auto-expire in 24h.
  static Future<EncryptedMediaResult> encryptAndUploadBytes({
    required Uint8List bytes,
    required String backendUrl,
  }) async {
    final secretKey = await cipher.newSecretKey();
    final nonce = cipher.newNonce();

    final secretBox = await cipher.encrypt(
      bytes,
      secretKey: secretKey,
      nonce: nonce,
    );

    final encryptedPayload = secretBox.concatenation();
    final fileKey = "${const Uuid().v4()}.enc";

    final uri = Uri.parse("$backendUrl/api/media/upload/$fileKey");
    final response = await http.put(
      uri,
      headers: {'Content-Type': 'application/octet-stream'},
      body: encryptedPayload,
    );

    if (response.statusCode != 200) {
      throw Exception("Failed to upload encrypted blob (${response.statusCode})");
    }

    final keyBytes = await secretKey.extractBytes();
    return EncryptedMediaResult(
      fileKey: fileKey,
      secretKeyHex: _toHex(keyBytes),
      nonceHex: _toHex(nonce),
    );
  }

  /// Download ciphertext from ephemeral storage and decrypt locally.
  static Future<Uint8List> downloadAndDecrypt({
    required String fileKey,
    required String secretKeyHex,
    required String nonceHex,
    required String backendUrl,
  }) async {
    final uri = Uri.parse("$backendUrl/api/media/download/$fileKey");
    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception("Blob expired or missing (${response.statusCode})");
    }

    final encryptedBytes = response.bodyBytes;

    final secretKeyBytes = _fromHex(secretKeyHex);
    final secretKey = SecretKey(secretKeyBytes);
    final secretBox = SecretBox.fromConcatenation(
      encryptedBytes,
      nonceLength: 12,
      macLength: 16,
    );

    final decryptedBytes = await cipher.decrypt(secretBox, secretKey: secretKey);
    return Uint8List.fromList(decryptedBytes);
  }

  static String _toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _fromHex(String hex) {
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    return List.generate(
      clean.length ~/ 2,
      (i) => int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16),
    );
  }
}
