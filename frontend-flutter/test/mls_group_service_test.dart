import 'dart:convert';
import 'dart:typed_data';

import 'package:air_chat/core/crypto/mls_group_service.dart';
import 'package:air_chat/models/group.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openmls/openmls.dart';

/// These tests exercise the real OpenMLS implementation, not a fake: each
/// "device" below owns an ephemeral MLS engine backed by its own in-memory
/// SQLCipher database, and every key package, welcome, commit and application
/// message on the wire is genuine RFC 9420 material.
///
/// That matters because the whole point of adopting MLS is to stop being the
/// author of the group key schedule. A test against a stub would only confirm
/// that the stub agrees with itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MlsGroupService alice;
  late MlsGroupService bob;
  late MlsGroupService carol;

  const groupId = 'grp_test_group';
  const aliceUid = 'uid_alice';
  const bobUid = 'uid_bob';
  const carolUid = 'uid_carol';

  setUp(() {
    alice = MlsGroupService(ephemeral: true);
    bob = MlsGroupService(ephemeral: true);
    carol = MlsGroupService(ephemeral: true);
  });

  tearDown(() async {
    await alice.close();
    await bob.close();
    await carol.close();
  });

  Future<Uint8List> keyPackageFor(MlsGroupService device, String uid) =>
      device.generateKeyPackage(selfUid: uid);

  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

  group('GroupCrypto version tag', () {
    test('existing groups default to the legacy shared key', () {
      final existing = Group(
        id: groupId,
        name: 'Old group',
        memberUids: const [aliceUid, bobUid],
        createdAt: 0,
      );
      expect(existing.cryptoVersion, GroupCrypto.legacySharedKey);
      expect(existing.usesMls, isFalse);
    });

    test('only version 2 and above is MLS', () {
      expect(GroupCrypto.usesMls(GroupCrypto.legacySharedKey), isFalse);
      expect(GroupCrypto.usesMls(GroupCrypto.mls), isTrue);
      expect(GroupCrypto.usesMls(GroupCrypto.mls + 1), isTrue);
    });

    test('round-trips through the database map', () {
      final mls = Group(
        id: groupId,
        name: 'New group',
        memberUids: const [aliceUid],
        createdAt: 1,
        cryptoVersion: GroupCrypto.mls,
      );
      expect(Group.fromMap(mls.toMap()).cryptoVersion, GroupCrypto.mls);
    });

    test('a row written before the column existed reads as legacy', () {
      final legacyRow = <String, dynamic>{
        'id': groupId,
        'name': 'Old group',
        'member_uids': jsonEncode([aliceUid]),
        'created_at': 0,
        'group_key': base64Encode(List<int>.filled(32, 7)),
        'key_version': 3,
        'unread_count': 0,
      };
      expect(
        Group.fromMap(legacyRow).cryptoVersion,
        GroupCrypto.legacySharedKey,
      );
    });
  });

  group('MLS group lifecycle', () {
    test('creator starts alone in epoch 0 on the pinned ciphersuite', () async {
      await alice.createGroup(groupId: groupId, selfUid: aliceUid);

      expect(await alice.members(groupId), [aliceUid]);
      expect(await alice.epoch(groupId), 0);
      expect(await alice.hasGroup(groupId), isTrue);
      expect(
        await alice.negotiatedCiphersuite(groupId),
        MlsCiphersuite.mls128DhkemX25519Chacha20Poly1305Sha256Ed25519,
      );
    });

    test('adding a member advances the epoch and both sides agree', () async {
      await alice.createGroup(groupId: groupId, selfUid: aliceUid);
      final bobPackage = await keyPackageFor(bob, bobUid);

      final added = await alice.addMembers(
        groupId: groupId,
        keyPackages: [bobPackage],
      );
      await bob.joinFromWelcome(
        expectedGroupId: groupId,
        welcome: added.welcome,
      );

      expect((await alice.members(groupId))..sort(), [aliceUid, bobUid]);
      expect((await bob.members(groupId))..sort(), [aliceUid, bobUid]);
      expect(await alice.epoch(groupId), 1);
      expect(await bob.epoch(groupId), 1);
    });

    test('a welcome for another group is refused', () async {
      await alice.createGroup(groupId: groupId, selfUid: aliceUid);
      final bobPackage = await keyPackageFor(bob, bobUid);
      final added = await alice.addMembers(
        groupId: groupId,
        keyPackages: [bobPackage],
      );

      await expectLater(
        bob.joinFromWelcome(
          expectedGroupId: 'grp_someone_elses_group',
          welcome: added.welcome,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('entry for an unknown group reports no state', () async {
      await alice.createGroup(groupId: groupId, selfUid: aliceUid);
      expect(await bob.hasGroup(groupId), isFalse);
    });
  });

  group('MLS messaging', () {
    test(
      'two members exchange messages with the sender authenticated',
      () async {
        await alice.createGroup(groupId: groupId, selfUid: aliceUid);
        final bobPackage = await keyPackageFor(bob, bobUid);
        final added = await alice.addMembers(
          groupId: groupId,
          keyPackages: [bobPackage],
        );
        await bob.joinFromWelcome(
          expectedGroupId: groupId,
          welcome: added.welcome,
        );

        final fromAlice = await alice.encrypt(
          groupId: groupId,
          plaintext: bytes('hello from alice'),
        );
        final received = await bob.decrypt(
          groupId: groupId,
          message: fromAlice,
        );
        expect(received.plaintext, 'hello from alice');
        expect(received.senderUid, aliceUid);
        expect(received.appliedCommit, isFalse);

        final fromBob = await bob.encrypt(
          groupId: groupId,
          plaintext: bytes('hello from bob'),
        );
        final back = await alice.decrypt(groupId: groupId, message: fromBob);
        expect(back.plaintext, 'hello from bob');
        expect(back.senderUid, bobUid);
      },
    );

    test('a third member is admitted and can then read', () async {
      await alice.createGroup(groupId: groupId, selfUid: aliceUid);
      final bobPackage = await keyPackageFor(bob, bobUid);
      final addedBob = await alice.addMembers(
        groupId: groupId,
        keyPackages: [bobPackage],
      );
      await bob.joinFromWelcome(
        expectedGroupId: groupId,
        welcome: addedBob.welcome,
      );

      final carolPackage = await keyPackageFor(carol, carolUid);
      final addedCarol = await alice.addMembers(
        groupId: groupId,
        keyPackages: [carolPackage],
      );
      await carol.joinFromWelcome(
        expectedGroupId: groupId,
        welcome: addedCarol.welcome,
      );
      await bob.decrypt(groupId: groupId, message: addedCarol.commit);

      expect((await alice.members(groupId))..sort(), [
        aliceUid,
        bobUid,
        carolUid,
      ]);
      expect(await carol.epoch(groupId), 2);
      expect(await bob.epoch(groupId), 2);

      final message = await carol.encrypt(
        groupId: groupId,
        plaintext: bytes('carol here'),
      );
      expect(
        (await alice.decrypt(groupId: groupId, message: message)).plaintext,
        'carol here',
      );
      expect(
        (await bob.decrypt(groupId: groupId, message: message)).plaintext,
        'carol here',
      );
    });

    test('a replayed commit is rejected by the ratchet', () async {
      await alice.createGroup(groupId: groupId, selfUid: aliceUid);
      final bobPackage = await keyPackageFor(bob, bobUid);
      final added = await alice.addMembers(
        groupId: groupId,
        keyPackages: [bobPackage],
      );
      await bob.joinFromWelcome(
        expectedGroupId: groupId,
        welcome: added.welcome,
      );

      // Bob joined at the epoch this commit produced, so by the time it reaches
      // him it is already applied. The relay is unordered and replayable, so
      // this is a routine case, not a hypothetical one.
      expect(await bob.epoch(groupId), 1);
      await expectLater(
        bob.decrypt(groupId: groupId, message: added.commit),
        throwsA(anything),
      );
      expect(await bob.epoch(groupId), 1);

      // A message sealed at this epoch still opens afterwards, so rejecting the
      // replay did not damage the live state.
      final probe = await alice.encrypt(
        groupId: groupId,
        plaintext: bytes('still working'),
      );
      expect(
        (await bob.decrypt(groupId: groupId, message: probe)).plaintext,
        'still working',
      );
    });

    test(
      'a commit cannot be processed by a device that then diverges',
      () async {
        // Two devices must reach the *same* epoch from the same commit; if they
        // did not, the group would have silently forked.
        await alice.createGroup(groupId: groupId, selfUid: aliceUid);
        final bobPackage = await keyPackageFor(bob, bobUid);
        final added = await alice.addMembers(
          groupId: groupId,
          keyPackages: [bobPackage],
        );
        await bob.joinFromWelcome(
          expectedGroupId: groupId,
          welcome: added.welcome,
        );

        final carolPackage = await keyPackageFor(carol, carolUid);
        final next = await alice.addMembers(
          groupId: groupId,
          keyPackages: [carolPackage],
        );
        await bob.decrypt(groupId: groupId, message: next.commit);
        await carol.joinFromWelcome(
          expectedGroupId: groupId,
          welcome: next.welcome,
        );

        expect(await alice.epoch(groupId), await bob.epoch(groupId));
        expect(await bob.epoch(groupId), await carol.epoch(groupId));

        // Same plaintext on both sides implies the same key schedule.
        final probe = await alice.encrypt(
          groupId: groupId,
          plaintext: bytes('epoch agreement'),
        );
        expect(
          (await carol.decrypt(groupId: groupId, message: probe)).plaintext,
          'epoch agreement',
        );
      },
    );
  });

  group('MLS revocation and forward secrecy', () {
    test(
      'a removed member cannot read messages sent after the removal',
      () async {
        await alice.createGroup(groupId: groupId, selfUid: aliceUid);
        final bobPackage = await keyPackageFor(bob, bobUid);
        final addedBob = await alice.addMembers(
          groupId: groupId,
          keyPackages: [bobPackage],
        );
        await bob.joinFromWelcome(
          expectedGroupId: groupId,
          welcome: addedBob.welcome,
        );

        final carolPackage = await keyPackageFor(carol, carolUid);
        final addedCarol = await alice.addMembers(
          groupId: groupId,
          keyPackages: [carolPackage],
        );
        await bob.decrypt(groupId: groupId, message: addedCarol.commit);
        await carol.joinFromWelcome(
          expectedGroupId: groupId,
          welcome: addedCarol.welcome,
        );

        // Carol can read while she is a member.
        final beforeRemoval = await alice.encrypt(
          groupId: groupId,
          plaintext: bytes('before removal'),
        );
        expect(
          (await carol.decrypt(
            groupId: groupId,
            message: beforeRemoval,
          )).plaintext,
          'before removal',
        );

        final removal = await alice.removeMembers(
          groupId: groupId,
          uids: [carolUid],
        );
        await bob.decrypt(groupId: groupId, message: removal);

        expect((await alice.members(groupId))..sort(), [aliceUid, bobUid]);

        final afterRemoval = await alice.encrypt(
          groupId: groupId,
          plaintext: bytes('after removal'),
        );

        // Bob, still a member, reads it.
        expect(
          (await bob.decrypt(
            groupId: groupId,
            message: afterRemoval,
          )).plaintext,
          'after removal',
        );

        // Carol, removed, cannot — this is the revocation itself.
        await expectLater(
          carol.decrypt(groupId: groupId, message: afterRemoval),
          throwsA(anything),
        );
      },
    );

    test('a member joining later cannot read earlier traffic', () async {
      await alice.createGroup(groupId: groupId, selfUid: aliceUid);
      final bobPackage = await keyPackageFor(bob, bobUid);
      final addedBob = await alice.addMembers(
        groupId: groupId,
        keyPackages: [bobPackage],
      );
      await bob.joinFromWelcome(
        expectedGroupId: groupId,
        welcome: addedBob.welcome,
      );

      // Captured while Carol is not yet a member.
      final epochOneTraffic = await alice.encrypt(
        groupId: groupId,
        plaintext: bytes('secret from before carol'),
      );
      expect(
        (await bob.decrypt(
          groupId: groupId,
          message: epochOneTraffic,
        )).plaintext,
        'secret from before carol',
      );

      final carolPackage = await keyPackageFor(carol, carolUid);
      final addedCarol = await alice.addMembers(
        groupId: groupId,
        keyPackages: [carolPackage],
      );
      await carol.joinFromWelcome(
        expectedGroupId: groupId,
        welcome: addedCarol.welcome,
      );

      // Carol joined at a later epoch and never held the earlier keys.
      await expectLater(
        carol.decrypt(groupId: groupId, message: epochOneTraffic),
        throwsA(anything),
      );
    });
  });
}
