import 'dart:collection';
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

/// Simple in-memory LRU cache for decrypted media bytes.
/// Prevents re-downloading and re-decrypting images on ListView rebuilds.
class DecryptedMediaCache {
  static const int _maxEntries = 25;
  static const int _maxTotalBytes = 50 * 1024 * 1024; // ~50 MB

  static final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  static int _totalBytes = 0;

  static Uint8List? get(String fileKey) {
    final bytes = _cache.remove(fileKey);
    if (bytes != null) {
      // Re-insert to mark as most-recently used.
      _cache[fileKey] = bytes;
    }
    return bytes;
  }

  static void put(String fileKey, Uint8List bytes) {
    if (_cache.containsKey(fileKey)) {
      _cache.remove(fileKey);
    }
    _cache[fileKey] = bytes;
    _totalBytes += bytes.length;

    // Evict oldest entries until under both limits.
    while (_cache.length > _maxEntries || _totalBytes > _maxTotalBytes) {
      final oldest = _cache.keys.first;
      final removed = _cache.remove(oldest)!;
      _totalBytes -= removed.length;
    }
  }

  static void clear() {
    _cache.clear();
    _totalBytes = 0;
  }
}

class MediaPipeline {
  static final cipher = Chacha20.poly1305Aead();
  static const int _maxRetries = 3;

  /// Encrypt raw bytes client-side and stream to ephemeral KV storage.
  /// Server never sees keys or plaintext — blobs auto-expire in 24h.
  /// Retries up to 3 times with exponential backoff on transient failures.
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

    for (int attempt = 1; attempt <= _maxRetries; attempt++) {
      try {
        final response = await http.put(
          uri,
          headers: {'Content-Type': 'application/octet-stream'},
          body: encryptedPayload,
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          final keyBytes = await secretKey.extractBytes();
          return EncryptedMediaResult(
            fileKey: fileKey,
            secretKeyHex: _toHex(keyBytes),
            nonceHex: _toHex(nonce),
          );
        }
        if (attempt == _maxRetries) {
          throw Exception("Failed to upload encrypted blob (${response.statusCode}) after $_maxRetries attempts");
        }
      } catch (e) {
        if (attempt == _maxRetries) rethrow;
      }
      await Future.delayed(Duration(seconds: attempt * 2));
    }
    throw Exception("Upload failed unexpectedly");
  }

  /// Download ciphertext from ephemeral storage and decrypt locally.
  /// Checks the in-memory cache first to avoid redundant network+crypto work.
  /// Retries up to 3 times with exponential backoff on transient failures.
  static Future<Uint8List> downloadAndDecrypt({
    required String fileKey,
    required String secretKeyHex,
    required String nonceHex,
    required String backendUrl,
  }) async {
    // Check cache first — instant return if already decrypted.
    final cached = DecryptedMediaCache.get(fileKey);
    if (cached != null) return cached;

    final uri = Uri.parse("$backendUrl/api/media/download/$fileKey");
    http.Response? response;

    for (int attempt = 1; attempt <= _maxRetries; attempt++) {
      try {
        response = await http.get(uri).timeout(const Duration(seconds: 30));
        if (response.statusCode == 200) break;
        if (attempt == _maxRetries) {
          throw Exception("Blob expired or missing (${response.statusCode})");
        }
      } catch (e) {
        if (attempt == _maxRetries) rethrow;
      }
      await Future.delayed(Duration(seconds: attempt * 2));
    }

    final encryptedBytes = response!.bodyBytes;

    final secretKeyBytes = _fromHex(secretKeyHex);
    final secretKey = SecretKey(secretKeyBytes);
    final secretBox = SecretBox.fromConcatenation(
      encryptedBytes,
      nonceLength: 12,
      macLength: 16,
    );

    final decryptedBytes = await cipher.decrypt(secretBox, secretKey: secretKey);
    final result = Uint8List.fromList(decryptedBytes);

    // Cache for future renders.
    DecryptedMediaCache.put(fileKey, result);

    return result;
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
