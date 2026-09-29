import 'dart:convert';

import 'package:air_chat/core/crypto/safety_number.dart';
import 'package:air_chat/models/contact.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic stand-in key material: 32-byte X25519 keys as base64, 32-byte
/// Ed25519 keys as hex (the encodings the app actually stores).
String b64Key(int seed) =>
    base64Encode(List<int>.generate(32, (i) => (seed + i) % 256));

String hexKey(int seed) => List<int>.generate(
  32,
  (i) => (seed * 7 + i) % 256,
).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<String> computeAliceBob({
  String aliceUid = 'alice',
  String bobUid = 'bob',
  String aliceId = '',
  String bobId = '',
}) async {
  final sn = await SafetyNumberCalculator.compute(
    localUid: aliceUid,
    localIdentityKey: aliceId.isEmpty ? b64Key(1) : aliceId,
    localSigningKey: hexKey(2),
    peerUid: bobUid,
    peerIdentityKey: bobId.isEmpty ? b64Key(3) : bobId,
    peerSigningKey: hexKey(4),
  );
  return sn.digits;
}

void main() {
  group('SafetyNumberCalculator', () {
    test('is symmetric — both parties derive the same number', () async {
      // Alice's view of Bob.
      final fromAlice = await SafetyNumberCalculator.compute(
        localUid: 'alice',
        localIdentityKey: b64Key(1),
        localSigningKey: hexKey(2),
        peerUid: 'bob',
        peerIdentityKey: b64Key(3),
        peerSigningKey: hexKey(4),
      );
      // Bob's view of Alice: same keys, roles swapped.
      final fromBob = await SafetyNumberCalculator.compute(
        localUid: 'bob',
        localIdentityKey: b64Key(3),
        localSigningKey: hexKey(4),
        peerUid: 'alice',
        peerIdentityKey: b64Key(1),
        peerSigningKey: hexKey(2),
      );
      expect(fromAlice.digits, fromBob.digits);
    });

    test('is deterministic for identical inputs', () async {
      expect(await computeAliceBob(), await computeAliceBob());
    });

    test('changes when the peer identity key changes', () async {
      final baseline = await computeAliceBob();
      final tampered = await computeAliceBob(bobId: b64Key(99));
      expect(tampered, isNot(baseline));
    });

    test('changes when the peer signing key changes', () async {
      final baseline = await computeAliceBob();
      final other = await SafetyNumberCalculator.compute(
        localUid: 'alice',
        localIdentityKey: b64Key(1),
        localSigningKey: hexKey(2),
        peerUid: 'bob',
        peerIdentityKey: b64Key(3),
        peerSigningKey: hexKey(77),
      );
      expect(other.digits, isNot(baseline));
    });

    test(
      'differs per peer — a number does not identify the local user alone',
      () async {
        final withBob = await computeAliceBob(bobUid: 'bob');
        final withCarol = await SafetyNumberCalculator.compute(
          localUid: 'alice',
          localIdentityKey: b64Key(1),
          localSigningKey: hexKey(2),
          peerUid: 'carol',
          peerIdentityKey: b64Key(3),
          peerSigningKey: hexKey(4),
        );
        expect(withCarol.digits, isNot(withBob));
      },
    );

    test('ignores hex letter case in the signing key', () async {
      // The same key written two ways must not look like two keys — on the QR
      // path one side may emit uppercase while the directory holds lowercase.
      final lower = await SafetyNumberCalculator.compute(
        localUid: 'alice',
        localIdentityKey: b64Key(1),
        localSigningKey: hexKey(2),
        peerUid: 'bob',
        peerIdentityKey: b64Key(3),
        peerSigningKey: hexKey(4),
      );
      final upper = await SafetyNumberCalculator.compute(
        localUid: 'alice',
        localIdentityKey: b64Key(1),
        localSigningKey: hexKey(2).toUpperCase(),
        peerUid: 'bob',
        peerIdentityKey: b64Key(3),
        peerSigningKey: hexKey(4).toUpperCase(),
      );
      expect(upper.digits, lower.digits);
    });

    test('ignores whitespace inside the base64 identity key', () async {
      final clean = await computeAliceBob();
      final spaced = await SafetyNumberCalculator.compute(
        localUid: 'alice',
        localIdentityKey: b64Key(1),
        localSigningKey: hexKey(2),
        peerUid: 'bob',
        peerIdentityKey: '  ${b64Key(3)}\n',
        peerSigningKey: hexKey(4),
      );
      expect(spaced.digits, clean);
    });

    test('refuses to derive a number without the signing key', () async {
      // The code covers the signing key, so without it there is genuinely
      // nothing to have verified — this must not silently degrade to identity
      // key only.
      await expectLater(
        SafetyNumberCalculator.compute(
          localUid: 'alice',
          localIdentityKey: b64Key(1),
          localSigningKey: hexKey(2),
          peerUid: 'bob',
          peerIdentityKey: b64Key(3),
          peerSigningKey: '',
        ),
        throwsA(isA<SafetyNumberUnavailable>()),
      );
    });

    test('refuses malformed key material', () async {
      await expectLater(
        SafetyNumberCalculator.compute(
          localUid: 'alice',
          localIdentityKey: 'not-base64!!',
          localSigningKey: hexKey(2),
          peerUid: 'bob',
          peerIdentityKey: b64Key(3),
          peerSigningKey: hexKey(4),
        ),
        throwsA(isA<SafetyNumberUnavailable>()),
      );
      await expectLater(
        SafetyNumberCalculator.compute(
          localUid: 'alice',
          localIdentityKey: b64Key(1),
          localSigningKey: 'zzzz',
          peerUid: 'bob',
          peerIdentityKey: b64Key(3),
          peerSigningKey: hexKey(4),
        ),
        throwsA(isA<SafetyNumberUnavailable>()),
      );
    });

    test('refuses when both sides report the same user id', () async {
      await expectLater(
        computeAliceBob(aliceUid: 'same', bobUid: 'same'),
        throwsA(isA<SafetyNumberUnavailable>()),
      );
    });

    test('digitsOrNull returns null instead of throwing', () async {
      final ok = await SafetyNumberCalculator.digitsOrNull(
        localUid: 'alice',
        localIdentityKey: b64Key(1),
        localSigningKey: hexKey(2),
        peerUid: 'bob',
        peerIdentityKey: b64Key(3),
        peerSigningKey: hexKey(4),
      );
      expect(ok, isNotNull);
      final missing = await SafetyNumberCalculator.digitsOrNull(
        localUid: 'alice',
        localIdentityKey: b64Key(1),
        localSigningKey: hexKey(2),
        peerUid: 'bob',
        peerIdentityKey: b64Key(3),
        peerSigningKey: '',
      );
      expect(missing, isNull);
    });

    test('produces 60 digits in twelve 5-digit blocks', () async {
      final sn = await SafetyNumberCalculator.compute(
        localUid: 'alice',
        localIdentityKey: b64Key(1),
        localSigningKey: hexKey(2),
        peerUid: 'bob',
        peerIdentityKey: b64Key(3),
        peerSigningKey: hexKey(4),
      );
      expect(sn.digits, matches(RegExp(r'^\d{60}$')));
      expect(sn.blocks, hasLength(12));
      for (final block in sn.blocks) {
        expect(block, matches(RegExp(r'^\d{5}$')));
      }
      expect(sn.display, hasLength(60 + 11));
    });

    test(
      'lays the code out in three rows of four blocks for reading',
      () async {
        final sn = await SafetyNumberCalculator.compute(
          localUid: 'alice',
          localIdentityKey: b64Key(1),
          localSigningKey: hexKey(2),
          peerUid: 'bob',
          peerIdentityKey: b64Key(3),
          peerSigningKey: hexKey(4),
        );
        expect(sn.rows, hasLength(3));
        for (final row in sn.rows) {
          expect(row, matches(RegExp(r'^\d{5} \d{5} \d{5} \d{5}$')));
        }
      },
    );
  });

  group('Contact verification state', () {
    final identity = b64Key(3);
    final signing = hexKey(4);

    Contact build({String? verifiedId, String? verifiedSigning}) => Contact(
      uid: 'bob',
      username: 'Bob',
      identityPublicKey: identity,
      signingPublicKey: signing,
      createdAt: 1,
      verifiedIdentityKey: verifiedId,
      verifiedSigningKey: verifiedSigning,
      verifiedAt: verifiedId == null ? null : 1,
    );

    test('is unverified until a comparison is recorded', () {
      final contact = build();
      expect(contact.isVerified, isFalse);
      expect(contact.hasKeyChanged, isFalse);
      expect(contact.isVerificationRecorded, isFalse);
    });

    test('is verified when the recorded keys match the live keys', () {
      final contact = build(verifiedId: identity, verifiedSigning: signing);
      expect(contact.isVerified, isTrue);
      expect(contact.hasKeyChanged, isFalse);
    });

    test('reports a change when the identity key is replaced', () {
      final contact = build(verifiedId: b64Key(55), verifiedSigning: signing);
      expect(contact.isVerified, isFalse);
      expect(contact.hasKeyChanged, isTrue);
    });

    test('reports a change when the signing key is replaced', () {
      final contact = build(verifiedId: identity, verifiedSigning: hexKey(77));
      expect(contact.isVerified, isFalse);
      expect(contact.hasKeyChanged, isTrue);
    });

    test('treats hex case as the same key, not a change', () {
      final contact = build(
        verifiedId: identity,
        verifiedSigning: signing.toUpperCase(),
      );
      expect(contact.isVerified, isTrue);
      expect(contact.hasKeyChanged, isFalse);
    });

    test('can never be verified without a signing key', () {
      final contact = Contact(
        uid: 'bob',
        username: 'Bob',
        identityPublicKey: identity,
        signingPublicKey: null,
        createdAt: 1,
        verifiedIdentityKey: identity,
        verifiedSigningKey: signing,
        verifiedAt: 1,
      );
      expect(contact.isVerified, isFalse);
      expect(contact.hasKeyChanged, isTrue);
    });

    test('toMap excludes verification columns', () {
      // Regression guard: insertContact writes via toMap-adjacent columns, and a
      // routine directory refresh must never be able to clear verification.
      final contact = build(verifiedId: identity, verifiedSigning: signing);
      final map = contact.toMap();
      expect(map.containsKey('verified_identity_key'), isFalse);
      expect(map.containsKey('verified_signing_key'), isFalse);
      expect(map.containsKey('verified_at'), isFalse);
    });

    test('fromMap reads verification columns when present', () {
      final contact = Contact.fromMap({
        'uid': 'bob',
        'username': 'Bob',
        'identity_public_key': identity,
        'signing_public_key': signing,
        'created_at': 1,
        'verified_identity_key': identity,
        'verified_signing_key': signing,
        'verified_at': 1234,
      });
      expect(contact.isVerified, isTrue);
      expect(contact.verifiedAt, 1234);
    });

    test('normalizeSigningKey collapses case and blank values', () {
      expect(Contact.normalizeSigningKey('AB CD'), 'abcd');
      expect(Contact.normalizeSigningKey(''), isNull);
      expect(Contact.normalizeSigningKey('   '), isNull);
      expect(Contact.normalizeSigningKey(null), isNull);
    });

    test('copyWith can adopt new keys without dropping verification state', () {
      final contact = build(verifiedId: identity, verifiedSigning: signing);
      final updated = contact.copyWith(identityPublicKey: b64Key(9));
      expect(updated.verifiedIdentityKey, identity);
      expect(updated.hasKeyChanged, isTrue);
    });
  });
}
