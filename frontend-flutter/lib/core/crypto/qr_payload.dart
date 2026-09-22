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
      var text = rawData.trim();
      // Strip BOM / zero-width chars some clipboards/messengers inject.
      text = text.replaceAll(RegExp('[\uFEFF\u200B\u200C\u200D\u2060]'), '');
      // Clipboard may wrap the JSON in quotes or extra text (shared via
      // chat apps) — extract the outermost {...} block.
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start < 0 || end < 0 || end <= start) return null;
      final map =
          jsonDecode(text.substring(start, end + 1)) as Map<String, dynamic>;
      final uid = map['uid']?.toString() ?? '';
      final pk = map['pk']?.toString() ?? '';
      if (uid.isEmpty || pk.isEmpty) return null;
      // Sanity: base64 X25519 keys decode to 32 bytes; reject garbage early.
      try {
        final normalized = pk.replaceAll(RegExp(r'\s+'), '');
        if (base64Decode(normalized).length != 32) return null;
      } catch (_) {
        return null;
      }
      return QrContactPayload(
        uid: uid,
        username: (map['username']?.toString() ?? '').isEmpty
            ? 'Peer'
            : map['username'].toString(),
        identityPublicKey: pk.replaceAll(RegExp(r'\s+'), ''),
      );
    } catch (_) {
      return null;
    }
  }
}
