import 'dart:convert';
import 'dart:typed_data';

import 'package:air_chat/core/crypto/mls_group_service.dart';
import 'package:air_chat/core/crypto/wire_envelope.dart';
import 'package:air_chat/models/group.dart';
import 'package:flutter_test/flutter_test.dart';

/// End-to-end checks over the *transport* the app actually uses for an MLS
/// group: an application message or a commit wrapped in a [WireEnvelope],
/// stringified, and decoded on the far side exactly as `MessageRouter` does it.
///
/// The group crypto itself is covered in `mls_group_service_test.dart`. What is
/// worth asserting here is the framing — that MLS traffic is distinguishable
/// from the legacy shared-key traffic the same channel still carries, and that a
/// commit arriving on that channel really does revoke a removed member.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const groupId = 'grp_transport';
  const aliceUid = 'uid_alice';
  const bobUid = 'uid_bob';
  const carolUid = 'uid_carol';

  late MlsGroupService alice;
  late MlsGroupService bob;

  setUp(() {
    alice = MlsGroupService(ephemeral: true);
    bob = MlsGroupService(ephemeral: true);
  });

  tearDown(() async {
    await alice.close();
    await bob.close();
  });

  /// Wrap a ciphertext the way the group send path does.
  String onTheWire(Uint8List ciphertext) => WireEnvelope(
    kind: WireEnvelope.kindMls,
    messageType: 0,
    ciphertext: ciphertext,
  ).encode();

  /// Unwrap the way the group receive path does.
  Uint8List offTheWire(String raw) {
    final envelope = WireEnvelope.tryDecode(raw);
    expect(envelope, isNotNull);
    expect(envelope!.kind, WireEnvelope.kindMls);
    return envelope.ciphertext;
  }

  /// Alice creates the group and admits Bob; Bob joins from the Welcome.
  Future<void> startGroupWithBob() async {
    final bobKeyPackage = await bob.generateKeyPackage(selfUid: bobUid);
    await alice.createGroup(groupId: groupId, selfUid: aliceUid);
    final added = await alice.addMembers(
      groupId: groupId,
      keyPackages: [bobKeyPackage],
    );
    await bob.joinFromWelcome(expectedGroupId: groupId, welcome: added.welcome);
  }

  test('an application message survives the envelope round trip', () async {
    await startGroupWithBob();

    final sealed = await alice.encrypt(
      groupId: groupId,
      plaintext: Uint8List.fromList(utf8.encode('hello group')),
    );

    final result = await bob.decrypt(
      groupId: groupId,
      message: offTheWire(onTheWire(sealed)),
    );
    expect(result.plaintext, 'hello group');
    // The sender is resolved from the ratchet tree, not from the relay.
    expect(result.senderUid, aliceUid);
    expect(result.appliedCommit, isFalse);
  });

  test(
    'a commit is delivered on the same channel and advances the epoch',
    () async {
      await startGroupWithBob();
      final carol = MlsGroupService(ephemeral: true);
      addTearDown(() async => carol.close());
      final epochBefore = await bob.epoch(groupId);

      // Alice adds Carol: the Welcome admits Carol, and the Commit is what
      // advances Bob — without it he stays on an epoch Alice has left.
      final added = await alice.addMembers(
        groupId: groupId,
        keyPackages: [await carol.generateKeyPackage(selfUid: carolUid)],
      );
      await carol.joinFromWelcome(
        expectedGroupId: groupId,
        welcome: added.welcome,
      );

      final processed = await bob.decrypt(
        groupId: groupId,
        message: offTheWire(onTheWire(added.commit)),
      );
      expect(processed.appliedCommit, isTrue);
      // A control message: nothing to display, but the epoch moved.
      expect(processed.plaintext, isNull);
      expect(await bob.epoch(groupId), greaterThan(epochBefore));
      expect(await bob.members(groupId), contains(carolUid));
    },
  );

  test('removal is enforced through the commit, not by a key change', () async {
    await startGroupWithBob();

    // Bob can read while he is a member.
    final before = await alice.encrypt(
      groupId: groupId,
      plaintext: Uint8List.fromList(utf8.encode('before removal')),
    );
    expect(
      (await bob.decrypt(
        groupId: groupId,
        message: offTheWire(onTheWire(before)),
      )).plaintext,
      'before removal',
    );

    final commit = await alice.removeMembers(groupId: groupId, uids: [bobUid]);
    final processed = await bob.decrypt(
      groupId: groupId,
      message: offTheWire(onTheWire(commit)),
    );
    // Bob cannot *apply* the commit that evicts him, so openmls refuses — and
    // that refusal is reported as eviction rather than swallowed as an error.
    // A dropped failure here would leave his client holding a group it can
    // never read again, with no explanation for the silence that follows.
    expect(processed.evicted, isTrue);
    expect(processed.appliedCommit, isFalse);

    // After the commit Bob is out of the epoch, so the next message's key is
    // one he cannot derive. This is the difference from rotating a shared key:
    // there is nothing he could have kept that still opens this.
    final after = await alice.encrypt(
      groupId: groupId,
      plaintext: Uint8List.fromList(utf8.encode('after removal')),
    );
    await expectLater(
      bob.decrypt(groupId: groupId, message: offTheWire(onTheWire(after))),
      throwsA(anything),
    );
  });

  test('legacy traffic is never mistaken for MLS traffic', () {
    // Exactly what the shared-key path puts on the wire today.
    final legacy = jsonEncode({'ct': 'AAAA', 'n': 'BBBB', 'epk': ''});
    expect(WireEnvelope.tryDecode(legacy), isNull);
    expect(WireEnvelope.tryDecode('{}'), isNull);
  });

  test('GroupCrypto keeps existing groups on the legacy scheme', () {
    final existing = Group(
      id: groupId,
      name: 'Old',
      memberUids: const [aliceUid, bobUid],
      createdAt: 0,
      groupKey: 'a2V5',
    );
    expect(existing.usesMls, isFalse);

    final created = Group(
      id: groupId,
      name: 'New',
      memberUids: const [aliceUid, bobUid],
      createdAt: 1,
      cryptoVersion: GroupCrypto.mls,
    );
    expect(created.usesMls, isTrue);
    // An MLS group has no shared key to leak or rotate.
    expect(created.groupKey, isNull);
  });
}
