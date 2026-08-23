import 'dart:convert';

class QrContactPayload {
  final String uid;
  final String username;
  final String identityPublicKey;

  QrContactPayload({
    required this.uid,
    required this.username,
    required this.identityPublicKey,
  });

  Map<String, dynamic> toJson() => {
        'airchat': 'v1',
        'uid': uid,
        'username': username,
        'pk': identityPublicKey,
      };

  String encode() => jsonEncode(toJson());

  static QrContactPayload? parse(String rawData) {
    try {
      final map = jsonDecode(rawData) as Map<String, dynamic>;
      if (map['uid'] == null || map['pk'] == null) return null;
      return QrContactPayload(
        uid: map['uid'],
        username: map['username'] ?? 'Peer',
        identityPublicKey: map['pk'],
      );
    } catch (_) {
      return null;
    }
  }
}
