import 'dart:convert';

import 'package:http/http.dart' as http;

import '../crypto/key_store.dart';
import '../crypto/signing_engine.dart';

class ApiClient {
  static const String defaultBaseUrl =
      "https://airchat-relay.malandkar-sarvesh1.workers.dev";
  final String baseUrl;

  const ApiClient({this.baseUrl = defaultBaseUrl});

  /// Signs [message] with this device's Ed25519 signing key. Returns null when
  /// no signing identity exists yet (callers then fail closed).
  Future<String?> _sign(String message) async {
    try {
      final kp = await KeyStore.getSigningKeyPair();
      if (kp == null) return null;
      return await SigningEngine().signHex(message, kp);
    } catch (_) {
      return null;
    }
  }

  /// Registers/refreshes this identity. The signature is bound to the uid
  /// (`register|uid|identityPublicKey`) so a third party who knows the uid
  /// cannot re-register it with their own keys and hijack the relay session.
  Future<bool> registerIdentity({
    required String uid,
    required String username,
    required String identityPublicKey,
    String signedPrekey = "",
    String prekeySignature = "",
    String? fcmToken,
  }) async {
    try {
      final signingPublicKey = await KeyStore.getSigningPublicKey();
      final signature = await _sign('register|$uid|$identityPublicKey');
      if (signingPublicKey == null ||
          signingPublicKey.isEmpty ||
          signature == null ||
          signature.isEmpty) {
        // No signing identity → cannot prove ownership. Fail closed.
        return false;
      }

      final uri = Uri.parse("$baseUrl/api/identity/register");
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'uid': uid,
              'username': username,
              'identityPublicKey': identityPublicKey,
              'signedPrekey': signedPrekey,
              'prekeySignature': prekeySignature,
              'signingPublicKey': signingPublicKey,
              'signingSignature': signature,
              if (fcmToken != null) 'fcmToken': fcmToken,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        // ignore: avoid_print
        print(
          '[AirChat] register HTTP ${response.statusCode}: ${response.body}',
        );
      }
      return response.statusCode == 200;
    } catch (e) {
      // ignore: avoid_print
      print('[AirChat] register exception: $e');
      return false;
    }
  }

  /// Asks the relay to send a data-only self-test push to this device.
  Future<bool> requestTestPush({required String uid}) async {
    try {
      final signature = await _sign('test_push|$uid');
      if (signature == null || signature.isEmpty) return false;
      final uri = Uri.parse("$baseUrl/api/identity/test-push");
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'uid': uid, 'signature': signature}),
          )
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> lookupIdentity({
    String? uid,
    String? username,
  }) async {
    try {
      final query = uid != null ? "uid=$uid" : "username=$username";
      final uri = Uri.parse("$baseUrl/api/identity/lookup?$query");
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> sendFcmToken(String token) async {
    try {
      final uid = await _getStoredUid();
      if (uid == null || uid.isEmpty) return false;
      final signature = await _sign('fcm_token|$uid|$token');
      if (signature == null || signature.isEmpty) return false;

      final uri = Uri.parse("$baseUrl/api/identity/fcm-token");
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'uid': uid,
          'fcmToken': token,
          'signature': signature,
        }),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _getStoredUid() async {
    return await KeyStore.getUid();
  }
}
