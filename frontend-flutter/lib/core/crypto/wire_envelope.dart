import 'dart:convert';
import 'dart:typed_data';

/// A versioned, self-describing envelope for the two new ciphertext families.
///
/// The legacy envelope is `{ct, n, epk}` — a bare X25519/ChaCha20-Poly1305
/// blob with no way to say what produced it. Adding a scheme that produces a
/// *different* shape of ciphertext therefore needs an envelope that says which
/// one it is, or a receiver has to guess.
///
/// So a v2 envelope is explicit:
///
/// ```json
/// { "v": 2, "k": "sig", "t": 3, "c": "<base64 ciphertext>" }
/// ```
///
///  * `v` — envelope version. Anything that is not 2 is the legacy format.
///  * `k` — cipher family: `sig` (libsignal Double Ratchet) or `mls`
///    (RFC 9420 application message / commit).
///  * `t` — libsignal ciphertext message type (2 = SignalMessage, 3 =
///    PreKeySignalMessage). Absent for MLS.
///  * `c` — the raw ciphertext bytes, base64.
///
/// ## Why the legacy decoder tolerates this
///
/// A client on a released build decodes every 1:1 payload with the legacy
/// reader, which looks only for `ct`/`n`/`epk`. Those are absent here, so it
/// reads an empty ciphertext and its AEAD open fails — the message is dropped,
/// not misread. That matters: the rollout rule is that a v2 message is only
/// ever *sent* to a peer that published a bundle, i.e. one that already knows
/// how to read this envelope. The failure mode for a mis-send is a dropped
/// message, never a wrong plaintext.
class WireEnvelope {
  /// Envelope version. 2 is the only non-legacy value.
  static const int version = 2;

  /// libsignal Double Ratchet ciphertext.
  static const String kindSignal = 'sig';

  /// MLS application message or membership commit.
  static const String kindMls = 'mls';

  /// Cipher family — [kindSignal] or [kindMls].
  final String kind;

  /// libsignal message type (see `CiphertextMessageType`). 0 for MLS.
  final int messageType;

  final Uint8List ciphertext;

  const WireEnvelope({
    required this.kind,
    required this.messageType,
    required this.ciphertext,
  });

  Map<String, dynamic> toJson() => {
    'v': version,
    'k': kind,
    't': messageType,
    'c': base64Encode(ciphertext),
  };

  String encode() => jsonEncode(toJson());

  /// Decodes a v2 envelope, or returns null when [raw] is not one.
  ///
  /// Returning null (rather than throwing) is deliberate: this is called on
  /// every inbound payload, most of which are legacy, and a malformed v2
  /// envelope must be treated as "not mine" rather than as an error that
  /// masks the legacy decode path.
  static WireEnvelope? tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['v'] != version) return null;
      final kind = decoded['k'];
      if (kind != kindSignal && kind != kindMls) return null;
      final encoded = decoded['c'];
      if (encoded is! String || encoded.isEmpty) return null;
      return WireEnvelope(
        kind: kind as String,
        messageType: decoded['t'] as int? ?? 0,
        ciphertext: base64Decode(encoded),
      );
    } catch (_) {
      return null;
    }
  }
}
