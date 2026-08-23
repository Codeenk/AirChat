import 'dart:convert';
import 'package:http/http.dart' as http;
import '../crypto/key_store.dart';

class ApiClient {
  static const String defaultBaseUrl = "https://airchat-relay.malandkar-sarvesh1.workers.dev";
  final String baseUrl;

  const ApiClient({this.baseUrl = defaultBaseUrl});

  Future<bool> registerIdentity({
    required String uid,
    required String username,
    required String identityPublicKey,
    String signedPrekey = "",
    String prekeySignature = "",
    String? signingPublicKey,
    String? signingSignature,
  }) async {
    try {
      final uri = Uri.parse("$baseUrl/api/identity/register");
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'uid': uid,
          'username': username,
          'identityPublicKey': identityPublicKey,
          'signedPrekey': signedPrekey,
          'prekeySignature': prekeySignature,
          if (signingPublicKey != null) 'signingPublicKey': signingPublicKey,
          if (signingSignature != null) 'signingSignature': signingSignature,
        }),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        // ignore: avoid_print
        print('[AirChat] register HTTP ${response.statusCode}: ${response.body}');
      }
      return response.statusCode == 200;
    } catch (e) {
      // ignore: avoid_print
      print('[AirChat] register exception: $e');
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
      if (uid == null) return false;

      final uri = Uri.parse("$baseUrl/api/identity/fcm-token");
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'uid': uid,
          'fcmToken': token,
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
