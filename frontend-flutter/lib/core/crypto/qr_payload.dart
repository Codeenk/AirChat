import 'dart:convert';

class QrContactPayload {
  final String uid;
  final String username;
  final String identityPublicKey;

  /// Ed25519 signing key, hex. Optional: older clients emit codes without it and
  /// the contact add path fills it in later from the directory. When present it
  /// is the peer's *own* claim about its signing key, so a code scanned in
  /// person is an out-of-band source — comparing it against the directory is
  /// what makes verification meaningful.
  final String? signingPublicKey;

  /// The 60-digit safety number the emitter computed. Optional, and never
  /// trusted on its own: the scanner recomputes it from the scanned keys and
  /// compares, which is what catches a code that was tampered with in transit.
  final String? safetyNumber;

  QrContactPayload({
    required this.uid,
    required this.username,
    required this.identityPublicKey,
    this.signingPublicKey,
    this.safetyNumber,
  });

  Map<String, dynamic> toJson() => {
    'airchat': 'v1',
    'uid': uid,
    'username': username,
    'pk': identityPublicKey,
    if (signingPublicKey != null && signingPublicKey!.isNotEmpty)
      'spk': signingPublicKey,
    if (safetyNumber != null && safetyNumber!.isNotEmpty) 'sn': safetyNumber,
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
      final spk = (map['spk']?.toString() ?? '').replaceAll(RegExp(r'\s+'), '');
      final sn = (map['sn']?.toString() ?? '').replaceAll(RegExp(r'\D'), '');
      return QrContactPayload(
        uid: uid,
        username: (map['username']?.toString() ?? '').isEmpty
            ? 'Peer'
            : map['username'].toString(),
        identityPublicKey: pk.replaceAll(RegExp(r'\s+'), ''),
        // Reject a malformed signing key rather than carrying garbage into a
        // comparison that would then look like a key mismatch.
        signingPublicKey: _isHex(spk) ? spk : null,
        safetyNumber: sn.length == 60 ? sn : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Even-length hex, non-empty. Guards the `spk` field so a corrupt code
  /// cannot masquerade as "the peer's key changed".
  static bool _isHex(String value) {
    if (value.isEmpty || value.length.isOdd) return false;
    if (value.length < 32) return false;
    return RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);
  }
}
