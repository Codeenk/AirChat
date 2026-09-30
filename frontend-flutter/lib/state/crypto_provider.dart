import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crash/crash_reporter.dart';
import '../core/crypto/delivery_tag.dart';
import '../core/crypto/key_store.dart';
import '../core/crypto/mls_group_service.dart';
import '../core/crypto/ratchet_session.dart';
import '../core/database/daos/contact_dao.dart';
import '../core/network/api_client.dart';

/// Relay kinds for published key material. Must match
/// `backend-worker/src/db/key_packages.ts`.
const String keyKindMls = 'mls';
const String keyKindSignal = 'signal';

final ratchetSessionProvider = Provider<RatchetSession>(
  (_) => RatchetSession.instance,
);

/// Publishes this device's two public blobs — an MLS KeyPackage and a libsignal
/// prekey bundle — so a peer can start a group or a ratchet session while this
/// device is offline.
///
/// Both are *offers*: a peer that wants to talk fetches them from the relay.
/// Publishing is best-effort and idempotent — the relay replaces the row and
/// resets its TTL — so it is retried every launch and a peer that is running an
/// older build simply has nothing to fetch.
///
/// KeepAlive: this must run at app start, with no screen open.
final keyPublicationProvider = Provider((ref) {
  ref.keepAlive();
  Future(() async {
    try {
      final uid = await KeyStore.getUid();
      if (uid == null || uid.isEmpty) return;
      final client = const ApiClient();

      // MLS KeyPackage: what a peer needs to add this device to a group.
      try {
        final keyPackage = await MlsGroupService.instance.generateKeyPackage(
          selfUid: uid,
        );
        await client.publishKeyPackage(
          uid: uid,
          kind: keyKindMls,
          payload: base64Encode(keyPackage),
        );
      } catch (e) {
        debugPrint('[AirChat] MLS KeyPackage publish skipped: $e');
      }

      // Double Ratchet bundle: what a peer needs to open a 1:1 ratchet.
      try {
        final session = RatchetSession.instance;
        await session.ensureReady();
        if (session.available) {
          // Mint or rotate the delivery tag before the bundle is built, so what
          // we publish is the tag this device is actually reachable on. Done
          // here rather than at send time because a peer needs it *before* any
          // message exists — the bundle is the only pre-session channel, and
          // the relay carries it as an opaque blob it never parses.
          try {
            await DeliveryTagRegistry.instance.ensureTag();
          } catch (_) {}
          final bundle = await session.localBundlePayload();
          if (bundle != null) {
            await client.publishKeyPackage(
              uid: uid,
              kind: keyKindSignal,
              payload: bundle,
            );
          }
        }
      } catch (e) {
        debugPrint('[AirChat] ratchet bundle publish skipped: $e');
      }
    } catch (_) {}
  });
  return null;
});

/// Resolves a peer's MLS KeyPackage.
///
/// Not cached: a KeyPackage is a single-use offer with a lifetime, and the one
/// advantage of fetching it fresh is that the peer's own client, not us, decides
/// whether the offer it published is still good. A null return means the peer
/// cannot be added to an MLS group yet.
Future<Uint8List?> fetchMlsKeyPackage(String peerUid) async {
  try {
    final payload = await const ApiClient().fetchKeyPackage(
      uid: peerUid,
      kind: keyKindMls,
    );
    if (payload == null) return null;
    return base64Decode(payload);
  } catch (_) {
    return null;
  }
}

/// The peer's identity key as the directory knows it, or null when unknown.
///
/// This is the key the safety number covers, so a bundle whose identity key
/// disagrees with it must be refused: otherwise the relay could serve a bundle
/// for an identity *it* holds and own every session built from it, before the
/// first-use trust rule has anything to compare against.
Future<String?> _directoryIdentityKey(String peerUid) async {
  try {
    final contact = await ContactDao().getContactByUid(peerUid);
    final local = contact?.identityPublicKey;
    if (local != null && local.isNotEmpty) return local;
    final info = await const ApiClient().lookupIdentity(uid: peerUid);
    final remote = info?['identity_public_key'] as String?;
    if (remote != null && remote.isNotEmpty) return remote;
  } catch (_) {}
  return null;
}

/// Whether a peer's published bundle really belongs to the identity the
/// directory (and the safety number) holds for it.
bool _bundleMatchesIdentity(RatchetBundle bundle, String directoryKeyBase64) {
  try {
    if (bundle.identityKey.length != 33) return false;
    // Strip libsignal's one-byte type prefix to compare against the app's
    // 32-byte X25519 identity key.
    final fromBundle = bundle.identityKey.sublist(1);
    final expected = base64Decode(directoryKeyBase64);
    if (fromBundle.length != expected.length) return false;
    for (var i = 0; i < fromBundle.length; i++) {
      if (fromBundle[i] != expected[i]) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Establishes a Double Ratchet session with [peerUid] if one does not exist.
///
/// Returns false — and the caller stays on the legacy path — whenever the peer
/// has published nothing, the relay cannot be reached, or the published bundle
/// does not match the identity the safety number covers. The last case is the
/// one that matters: everything else is availability, that one is an active
/// substitution attempt.
Future<bool> ensureRatchetSession(String peerUid) async {
  final session = RatchetSession.instance;
  try {
    await session.ensureReady();
    if (!session.available) return false;
    if (await session.hasSession(peerUid)) return true;

    final cached = await session.cachedPeerIdentity(peerUid);
    if (cached != null && cached.isEmpty) return false;

    final payload = await const ApiClient().fetchKeyPackage(
      uid: peerUid,
      kind: keyKindSignal,
    );
    if (payload == null) {
      await session.rememberPeer(peerUid, null);
      return false;
    }

    final bundle = RatchetBundle.tryDecode(payload);
    if (bundle == null) {
      await session.rememberPeer(peerUid, null);
      return false;
    }

    final directoryKey = await _directoryIdentityKey(peerUid);
    if (directoryKey == null) {
      // Cannot confirm the bundle belongs to the peer we think we are talking
      // to, so do not build a session on it. Not cached as "incapable":
      // this is a temporary inability to check, not a statement about the peer.
      return false;
    }
    if (!_bundleMatchesIdentity(bundle, directoryKey)) {
      CrashReporter.recordError(
        error:
            'published bundle identity does not match directory for $peerUid',
        source: 'ratchet-bundle',
      );
      // Refuse, and do not cache the peer as capable: the bundle on the relay
      // is not the peer's, and could be replaced by a correct one later.
      return false;
    }

    final ok = await session.ensureSession(peerUid, payload);
    if (ok) {
      await session.rememberPeer(
        peerUid,
        base64Encode(bundle.identityKey.sublist(1)),
      );
      // Note what is deliberately *not* done with `bundle.deliveryTag`: it is
      // not remembered as a place to seal to. A bundle proves only that the peer
      // published a tag, not that they can open anything sealed to it — sealing
      // needs them to hold *our* identity key, and a peer who added us without
      // us adding them holds nothing. Their client would then be unable to
      // attribute the message and it would expire, undelivered. So sealing waits
      // for proof, which is a tag inside a payload we decrypted
      // (`SealedSender.rememberPeerTag`, called from the receive path).
    }
    return ok;
  } catch (e) {
    CrashReporter.recordError(
      error: 'ratchet session setup failed for $peerUid: $e',
      source: 'ratchet-session',
    );
    return false;
  }
}
