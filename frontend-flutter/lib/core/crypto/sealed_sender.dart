import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal/libsignal.dart';

import '../database/daos/contact_dao.dart';
import '../network/websocket_client.dart';
import 'delivery_tag.dart';
import 'ratchet_session.dart';
import 'wire_envelope.dart';

/// A sealed message that was successfully opened, and the peer the payload's
/// own authentication says it came from.
class SealedInbound {
  /// Resolved by *decrypting*, never by the relay. See [SealedSender.open].
  final String senderUid;
  final String plaintext;

  const SealedInbound({required this.senderUid, required this.plaintext});
}

/// Client half of sealed sender: send without naming ourselves, and work out
/// who a sealed message came from.
///
/// The relay half (`backend-worker/src/durable-objects/ConnectionRelay.ts`) can
/// deliver a message it cannot attribute. That moves two jobs onto this device:
///
///  * **Sending** — address the *device* (`to`: the peer's delivery tag) and
///    quote our own tag as the return path, so the relay never sees a uid in
///    either direction. Only a payload that is self-attributing may ride this
///    path: a libsignal envelope authenticates its sender, the legacy X25519
///    envelope does not, so legacy payloads stay on the named transport
///    (`SECURITY_SEALED_SENDER.md` §5.1, §6).
///  * **Receiving** — recover the sender by trial decryption instead of being
///    told. A ratchet payload only opens against the session that produced it,
///    so the peer whose session decrypts *is* the sender, cryptographically.
///
/// ## Why trial decryption is safe, and why the hint is not used
///
/// A candidate set is only useful if a wrong candidate fails. Two cases:
///
///  * **An established session** (`SignalMessage`) — the message key comes from
///    that session's ratchet, so it opens under exactly one peer. Every other
///    candidate throws before touching stored state; libsignal only persists a
///    session change *after* a successful decrypt, so a failed attempt cannot
///    corrupt the ratchet. Concurrency is handled by the session's per-peer lock.
///  * **A first message** (`PreKeySignalMessage`) — has no session yet, so the
///    sender's identity key inside the envelope is what identifies them. It is
///    read *only* as a candidate filter and is explicitly unauthenticated on its
///    own (libsignal documents this); the decrypt that follows is what
///    authenticates, so a forged identity key buys an attacker one wasted
///    attempt, not a misattributed message. Candidates are drawn from contacts
///    whose identity key we already hold, which is what makes the filter honest.
///
/// The design reserved a `hint` field for an O(1) attribution shortcut
/// (`SECURITY_SEALED_SENDER.md` §5.4). It is deliberately unused: libsignal does
/// not expose the session root key that would make it non-linkable, and a
/// public-key-derived hint would be computable by the relay, handing back the
/// graph this whole design removes. Trial decryption costs a handful of failed
/// opens against a bounded candidate set, and it is not merely an optimisation —
/// the payload's authentication is the authority either way.
class SealedSender {
  SealedSender({
    DeliveryTagRegistry? tags,
    RatchetSession? ratchet,
    Future<Map<String, String>> Function()? knownIdentities,
  }) : _tags = tags ?? DeliveryTagRegistry.instance,
       _ratchet = ratchet ?? RatchetSession.instance,
       _knownIdentities = knownIdentities ?? _contactsWithIdentityKeys;

  /// App-wide instance. Tests construct their own with injected dependencies.
  static final SealedSender instance = SealedSender();

  /// libsignal ciphertext types, as carried in `WireEnvelope.messageType`.
  static const int typeSignal = 2;
  static const int typePreKey = 3;

  /// Cap on how many peers one inbound sealed packet may be tried against.
  ///
  /// A hostile relay can address any body to our tag, so unbounded trial
  /// decryption would be a cheap way to make the device burn CPU. The set is
  /// bounded instead: a first message is filtered by identity key down to
  /// (usually) one candidate, and an established session is found by walking our
  /// own sessions.
  static const int maxCandidates = 32;

  final DeliveryTagRegistry _tags;
  final RatchetSession _ratchet;
  final Future<Map<String, String>> Function() _knownIdentities;

  /// The tag this device is currently reachable on, or null when we have none
  /// (storage unavailable) — in which case nothing can be sealed to us and every
  /// send falls back to the named transport.
  Future<String?> currentTag() => _tags.currentTag();

  /// Registers our active tags with the relay. Idempotent; called on every
  /// connect so a lost row heals itself.
  Future<int> register(SealedTransport client, {String? fcmToken}) =>
      _tags.registerOn(client, fcmToken: fcmToken);

  /// The tag we know [peerUid] is reachable on, or null if they have never told
  /// us one (they may be on a build that predates sealed delivery).
  Future<String?> peerTagFor(String peerUid) => _ratchet.peerTag(peerUid);

  /// Records the tag a peer told us about, after validating its shape.
  ///
  /// Called only with a tag from the peer's own **decrypted payload**, which is
  /// also the only signal that they can be sealed to at all: a message they sent
  /// us on the ratchet means they hold our bundle, so they hold our identity key
  /// and will be able to attribute a sealed reply. A tag from their published
  /// bundle proves no such thing (see [send]), and the relay-supplied `reply`
  /// field proves nothing at all, so neither is used.
  Future<void> rememberPeerTag(String peerUid, String? tag) async {
    if (!DeliveryTag.isValid(tag)) return;
    await _ratchet.rememberPeerTag(peerUid, tag);
  }

  /// Sends [body] to [peerUid] without naming either end, returning whether it
  /// went out sealed.
  ///
  /// A `false` is not a failure: it means this message cannot use the sealed
  /// path yet (no tag for us, no tag for the peer, or a payload that does not
  /// authenticate its own sender) and the caller must use the legacy transport.
  /// `SECURITY_SEALED_SENDER.md` §6 — sealing is negotiated per message, never
  /// assumed, so a mixed-version population degrades instead of breaking.
  ///
  /// The gate is deliberately conservative, and it is what makes the metadata
  /// win *safe* rather than merely appealing: a message is only sealed once
  /// [peerTagFor] holds a tag the peer themselves put inside a payload we
  /// decrypted. Two things follow from that one condition — they can open what
  /// we send (their ratchet message proves they hold our identity key, so they
  /// can attribute us), and we know where to send it (their current tag, which
  /// is how a rotation reaches us). Sealing to a tag learned from a published
  /// bundle would skip both checks and could drop a legitimate message into the
  /// expiry sweep, because a recipient who cannot attribute us cannot show us
  /// the message either. So the first message of any pair still names its
  /// sender, and every message after it does not.
  Future<bool> send({
    required SealedTransport client,
    required String peerUid,
    required String packetId,
    required String body,
  }) async {
    try {
      final ourTag = await _tags.currentTag();
      if (ourTag == null) return false;

      // Only a self-attributing payload may ride sealed delivery. A legacy
      // X25519 envelope carries no sender identity, so sealing it would leave
      // the recipient unable to say who sent it — and would let anyone who can
      // pose as the relay force that downgrade.
      final envelope = WireEnvelope.tryDecode(body);
      if (envelope == null || envelope.kind != WireEnvelope.kindSignal) {
        return false;
      }

      final peerTag = await _ratchet.peerTag(peerUid);
      if (peerTag == null) return false;

      client.sendSealed(
        toTag: peerTag,
        replyTag: ourTag,
        packetId: packetId,
        body: body,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Opens an inbound sealed packet, resolving its sender or returning null when
  /// it is not ours to read.
  ///
  /// Null covers every uninteresting case — a body the relay invented, one for a
  /// session we do not hold, a payload rotated to a key we cannot open. None of
  /// them is an error worth surfacing to the user, and none of them may be
  /// treated as "the relay says this is from X".
  Future<SealedInbound?> open({
    required String body,
    required String packetId,
  }) async {
    final envelope = WireEnvelope.tryDecode(body);
    if (envelope == null || envelope.kind != WireEnvelope.kindSignal) {
      return null;
    }

    final candidates = await _candidatesFor(envelope);
    for (final uid in candidates) {
      try {
        final plaintext = await _ratchet.decrypt(uid, envelope);
        return SealedInbound(senderUid: uid, plaintext: plaintext);
      } catch (_) {
        // Wrong peer, or a body we cannot open. Neither mutates stored state
        // (libsignal commits a session change only after a successful decrypt),
        // so continuing to the next candidate is safe.
        continue;
      }
    }
    return null;
  }

  /// Confirms receipt of a sealed packet so the relay can drop its copy.
  ///
  /// [tag] is the tag the message *arrived on* (the relay owns packets per tag)
  /// and [replyTag] is the sender's return path. No identity is asserted, which
  /// is why this needs no authentication: an ack only deletes mail addressed to
  /// a tag this socket registered.
  void ack({
    required SealedTransport client,
    required String tag,
    required String packetId,
    String? replyTag,
  }) {
    client.sealAck(tag: tag, packetId: packetId, replyTag: replyTag);
  }

  /// Read receipt, routed the same way as [ack].
  void receipt({
    required SealedTransport client,
    required String tag,
    required String packetId,
    String? replyTag,
  }) {
    client.sealReceipt(tag: tag, packetId: packetId, replyTag: replyTag);
  }

  /// Which peers an inbound payload could have come from.
  ///
  /// Sessions first for a `SignalMessage` (the session is the only thing that
  /// can open it); identity-key match for a `PreKeySignalMessage` (there is no
  /// session yet, so the envelope's own identity key is the discriminator).
  Future<List<String>> _candidatesFor(WireEnvelope envelope) async {
    if (envelope.messageType == typeSignal) {
      return _cap(await _ratchet.sessionPeers());
    }
    if (envelope.messageType == typePreKey) {
      final claimed = _preKeyIdentityKey(envelope.ciphertext);
      if (claimed == null) return const [];
      final identities = await _knownIdentities();
      final matches = <String>[];
      for (final entry in identities.entries) {
        if (_sameIdentityKey(entry.value, claimed)) matches.add(entry.key);
      }
      return _cap(matches);
    }
    // Sender-key (7) and plaintext (8) do not appear in 1:1 conversations, and
    // anything else is not a ciphertext we can open.
    return const [];
  }

  static List<String> _cap(List<String> peers) =>
      peers.length > maxCandidates ? peers.sublist(0, maxCandidates) : peers;

  /// The sender identity key carried by a pre-key message, base64 of the raw
  /// 32 bytes (libsignal's leading type byte stripped), or null if unreadable.
  static String? _preKeyIdentityKey(Uint8List ciphertext) {
    try {
      final message = PreKeySignalMessage.deserialize(data: ciphertext);
      final key = message.identityKey();
      // libsignal serializes a public key with a leading type byte; accept a
      // bare 32-byte key too rather than silently finding no candidate at all.
      if (key.length == 33) return base64Encode(key.sublist(1));
      if (key.length == 32) return base64Encode(key);
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool _sameIdentityKey(String expectedBase64, String actualBase64) {
    try {
      final expected = base64Decode(expectedBase64);
      final actual = base64Decode(actualBase64);
      if (expected.length != actual.length) return false;
      for (var i = 0; i < expected.length; i++) {
        if (expected[i] != actual[i]) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Every local contact's identity key, by uid — the candidate pool for a peer
  /// we have never had a session with.
  static Future<Map<String, String>> _contactsWithIdentityKeys() async {
    try {
      final contacts = await ContactDao().getAllContacts();
      return {
        for (final c in contacts)
          if (c.identityPublicKey.isNotEmpty) c.uid: c.identityPublicKey,
      };
    } catch (_) {
      return const {};
    }
  }
}
