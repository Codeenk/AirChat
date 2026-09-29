import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Thrown when a safety number cannot be derived because the key material for
/// one of the two parties is missing, empty, or not decodable. Callers should
/// surface this as "not yet verifiable", never as a mismatch.
class SafetyNumberUnavailable implements Exception {
  final String reason;
  const SafetyNumberUnavailable(this.reason);

  @override
  String toString() => 'SafetyNumberUnavailable: $reason';
}

/// A 60-digit fingerprint of both parties' keys, in twelve 5-digit blocks.
///
/// The digits are what two users compare out of band. Everything else about
/// verification (storing it, warning on change) hangs off this value.
class SafetyNumber {
  /// 60 digits, no separators. Use this for storage and comparison.
  final String digits;

  /// The same digits as twelve 5-digit blocks, for reading aloud.
  final List<String> blocks;

  const SafetyNumber._(this.digits, this.blocks);

  /// Spaces between every block — one long line.
  String get display => blocks.join(' ');

  /// Three rows of four blocks, the layout Signal uses so the number is easier
  /// to track with a finger when comparing aloud.
  List<String> get rows => [
    blocks.sublist(0, 4).join(' '),
    blocks.sublist(4, 8).join(' '),
    blocks.sublist(8, 12).join(' '),
  ];

  @override
  String toString() => display;

  @override
  bool operator ==(Object other) =>
      other is SafetyNumber && other.digits == digits;

  @override
  int get hashCode => digits.hashCode;
}

/// Out-of-band key verification — the defence against a hostile directory.
///
/// ## Why this exists
///
/// A peer's identity and signing keys are fetched from the relay's public
/// directory (`GET /api/identity/lookup`). That means one party — the relay
/// operator — both *distributes the keys* and *routes the ciphertext*. A
/// malicious or compromised relay can answer a lookup with its own keys and
/// then sit in the middle of the conversation: decrypt, read, re-encrypt,
/// forward. Neither endpoint can notice from the ciphertext, because the
/// attacker is the one who supplied the keys in the first place.
///
/// This is the one attack that "the server cannot read your messages" does not
/// cover on its own, and no amount of encryption at the endpoint fixes it. The
/// only fix is for the two users to compare a value derived from *both* sets of
/// keys over a channel the relay does not control: in person, or read aloud on a
/// call where each recognises the other's voice.
///
/// ## Construction
///
/// ```
/// SHA-512( domain
///        || length-prefixed(uid_a) || length-prefixed(idKey_a) || length-prefixed(signKey_a)
///        || length-prefixed(uid_b) || length-prefixed(idKey_b) || length-prefixed(signKey_b) )
/// ```
///
/// where `[a, b]` are the two parties ordered by `uid`.
///
/// Three details carry the security, and each is deliberate:
///
/// * **Both parties contribute.** The number is therefore *symmetric*: Alice and
///   Bob compute the same 60 digits, so either can read it while the other
///   checks. A fingerprint of one key alone would not be.
/// * **The pair is ordered by uid**, so both devices serialise the transcript
///   identically. Equal uids are rejected rather than silently ordered, since
///   that would mean the same identity on both sides of the conversation.
/// * **Every field is length-prefixed** (4-byte big-endian). Without it, shifting
///   bytes across a field boundary would produce the same transcript; a shorter
///   uid with a longer key would forge a match. The domain string is
///   length-prefixed for the same reason.
///
/// Keys are hashed as *decoded bytes*, not as the strings that carry them. A
/// base64 key with stray whitespace or a hex key differing only in letter case
/// is the same key, and must produce the same number — otherwise two honest
/// clients would disagree and the user would see a false alarm.
///
/// The digest is reduced to twelve 5-digit blocks, matching the familiar Signal
/// presentation. SHA-512 is used as a plain collision-resistant hash: there is
/// no bespoke cryptography here beyond the documented transcript encoding, and
/// the security rests entirely on SHA-512's second-preimage resistance. The
/// final reduction discards a negligible fraction of the digest's entropy
/// (< 2^-19 of a 40-bit block), far below what 60 digits can express.
class SafetyNumberCalculator {
  static const _domain = 'AirChat-SafetyNumber-v1';
  static const _blockCount = 12;
  static const _digitsPerBlock = 5;

  /// Derives the shared fingerprint for a pair of identities.
  ///
  /// Throws [SafetyNumberUnavailable] when either side's keys are missing or
  /// malformed — callers must show that as "cannot verify yet", not as a
  /// failure of the verification itself.
  static Future<SafetyNumber> compute({
    required String localUid,
    required String localIdentityKey,
    required String localSigningKey,
    required String peerUid,
    required String peerIdentityKey,
    required String peerSigningKey,
  }) async {
    if (localUid.isEmpty || peerUid.isEmpty) {
      throw const SafetyNumberUnavailable('missing user id');
    }
    if (localUid == peerUid) {
      throw const SafetyNumberUnavailable(
        'both sides report the same user id — cannot pair an identity with itself',
      );
    }

    final parties = <_Party>[
      _Party(localUid, localIdentityKey, localSigningKey),
      _Party(peerUid, peerIdentityKey, peerSigningKey),
    ]..sort((a, b) => a.uid.compareTo(b.uid));

    final transcript = BytesBuilder(copy: false);
    _writeField(transcript, utf8.encode(_domain));
    for (final party in parties) {
      _writeField(transcript, utf8.encode(party.uid));
      _writeField(transcript, party.identityKeyBytes);
      _writeField(transcript, party.signingKeyBytes);
    }

    final digest = await Sha512().hash(transcript.toBytes());
    return _toBlocks(Uint8List.fromList(digest.bytes));
  }

  /// Convenience wrapper: derives the number and returns its digits, or `null`
  /// if the keys are not usable. Prefer [compute] when you want to explain why.
  static Future<String?> digitsOrNull({
    required String localUid,
    required String localIdentityKey,
    required String localSigningKey,
    required String peerUid,
    required String peerIdentityKey,
    required String peerSigningKey,
  }) async {
    try {
      final sn = await compute(
        localUid: localUid,
        localIdentityKey: localIdentityKey,
        localSigningKey: localSigningKey,
        peerUid: peerUid,
        peerIdentityKey: peerIdentityKey,
        peerSigningKey: peerSigningKey,
      );
      return sn.digits;
    } on SafetyNumberUnavailable {
      return null;
    }
  }

  static void _writeField(BytesBuilder out, List<int> value) {
    final length = value.length;
    out.addByte((length >> 24) & 0xff);
    out.addByte((length >> 16) & 0xff);
    out.addByte((length >> 8) & 0xff);
    out.addByte(length & 0xff);
    out.add(value);
  }

  static SafetyNumber _toBlocks(Uint8List digest) {
    final blocks = <String>[];
    var offset = 0;
    for (var i = 0; i < _blockCount; i++) {
      var value = 0;
      for (var j = 0; j < _digitsPerBlock; j++) {
        value = (value << 8) | digest[offset++];
      }
      blocks.add((value % 100000).toString().padLeft(_digitsPerBlock, '0'));
    }
    return SafetyNumber._(blocks.join(), blocks);
  }
}

class _Party {
  final String uid;
  final Uint8List identityKeyBytes;
  final Uint8List signingKeyBytes;

  _Party(this.uid, String identityKey, String signingKey)
    : identityKeyBytes = _decodeBase64Key(identityKey, 'identity key'),
      signingKeyBytes = _decodeHexKey(signingKey, 'signing key');

  static Uint8List _decodeBase64Key(String raw, String label) {
    final normalized = raw.replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty) {
      throw SafetyNumberUnavailable('missing $label');
    }
    try {
      final bytes = base64Decode(normalized);
      if (bytes.isEmpty) throw const FormatException('empty');
      return Uint8List.fromList(bytes);
    } on FormatException {
      throw SafetyNumberUnavailable('$label is not valid base64');
    }
  }

  /// Hex, not base64: signing keys are stored as lowercase hex today, but the
  /// decoder deliberately accepts either case so a future encoding change — or
  /// a peer that formats differently — cannot silently break verification.
  static Uint8List _decodeHexKey(String raw, String label) {
    var normalized = raw.replaceAll(RegExp(r'\s+'), '');
    if (normalized.startsWith('0x') || normalized.startsWith('0X')) {
      normalized = normalized.substring(2);
    }
    if (normalized.isEmpty) {
      throw SafetyNumberUnavailable('missing $label');
    }
    if (normalized.length.isOdd) {
      throw SafetyNumberUnavailable('$label has an odd number of hex digits');
    }
    final bytes = Uint8List(normalized.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      final byte = int.tryParse(
        normalized.substring(i * 2, i * 2 + 2),
        radix: 16,
      );
      if (byte == null) {
        throw SafetyNumberUnavailable('$label is not valid hex');
      }
      bytes[i] = byte;
    }
    return bytes;
  }
}
