import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

import '../core/crypto/direct_cipher.dart';
import '../core/crypto/key_store.dart';
import '../core/crypto/mls_group_service.dart';
import '../core/crypto/signing_engine.dart';
import '../core/crypto/wire_envelope.dart';
import '../core/database/daos/group_dao.dart';
import '../core/network/api_client.dart';
import '../models/group.dart';
import 'connection_provider.dart';
import 'crypto_provider.dart';

final groupDaoProvider = Provider((_) => GroupDao());

final groupsProvider = StreamProvider<List<Group>>((ref) async* {
  final dao = ref.watch(groupDaoProvider);
  yield await dao.getAllGroups();
  await for (final _ in ref.watch(refreshBusProvider).stream) {
    yield await dao.getAllGroups();
  }
});

/// Generates a random 32-byte symmetric key for ChaCha20-Poly1305 group encryption.
String _generateGroupKey() {
  final rng = Random.secure();
  final keyBytes = List<int>.generate(32, (_) => rng.nextInt(256));
  return base64Encode(keyBytes);
}

class GroupActions {
  final Ref ref;
  GroupActions(this.ref);

  /// Creates a group and fans out invites.
  ///
  /// **MLS when every member can take it, the legacy shared key otherwise.**
  /// A group is MLS only if each invited member has a published KeyPackage,
  /// which is the client's way of saying it understands RFC 9420. The check is
  /// all-or-nothing on purpose: one member on a released build means the whole
  /// group stays on the scheme that member can read, because an MLS group is
  /// unreadable to a client that cannot process the epoch — a mixed group would
  /// just be a group where that member sees nothing.
  Future<Group> createGroup({
    required String name,
    required List<String> memberUids,
  }) async {
    final myUid = await KeyStore.getUid() ?? '';
    final allMembers = {myUid, ...memberUids}.toList();
    final groupName = name.trim().isEmpty ? 'Group' : name.trim();
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    final groupId =
        'grp_${const Uuid().v4().replaceAll('-', '').substring(0, 16)}';

    if (memberUids.isNotEmpty) {
      final mls = await _tryCreateMlsGroup(
        groupId: groupId,
        groupName: groupName,
        createdAt: createdAt,
        myUid: myUid,
        allMembers: allMembers,
        memberUids: memberUids,
      );
      if (mls != null) return mls;
    }

    return _createLegacyGroup(
      groupId: groupId,
      groupName: groupName,
      createdAt: createdAt,
      myUid: myUid,
      allMembers: allMembers,
      memberUids: memberUids,
    );
  }

  /// Attempts MLS creation. Returns null when the group must fall back to the
  /// legacy scheme: a missing KeyPackage, or any failure while building the
  /// group. In that case nothing is left behind — the half-built MLS group is
  /// deleted so a later retry starts clean.
  Future<Group?> _tryCreateMlsGroup({
    required String groupId,
    required String groupName,
    required int createdAt,
    required String myUid,
    required List<String> allMembers,
    required List<String> memberUids,
  }) async {
    final service = MlsGroupService.instance;
    final packages = <Uint8List>[];
    for (final uid in memberUids) {
      final keyPackage = await fetchMlsKeyPackage(uid);
      if (keyPackage == null) return null;
      packages.add(keyPackage);
    }

    try {
      await service.createGroup(groupId: groupId, selfUid: myUid);
      final added = await service.addMembers(
        groupId: groupId,
        keyPackages: packages,
      );

      final group = Group(
        id: groupId,
        name: groupName,
        memberUids: allMembers,
        createdAt: createdAt,
        // No shared key: MLS derives every message key from the epoch secret,
        // so there is deliberately nothing here to leak or to rotate.
        groupKey: null,
        keyVersion: 1,
        cryptoVersion: GroupCrypto.mls,
      );
      // The Welcome is what actually admits each member: it carries the
      // ratchet tree, so the joiner needs nothing else and can authenticate
      // every leaf it is told about. A member who never receives one has no
      // leaf at all — the group would exist with a member who cannot read it —
      // so delivery failure aborts the whole MLS attempt here, before anything
      // is stored, and the caller falls back to the scheme everyone can read.
      for (final uid in memberUids) {
        final delivered = await _sendMlsWelcome(
          recipientUid: uid,
          group: group,
          welcome: added.welcome,
        );
        if (!delivered) {
          throw StateError('MLS welcome could not be delivered to $uid');
        }
      }

      await ref.read(groupDaoProvider).insertGroup(group);
      await _registerGroupWithServer(group);
      ref.invalidate(groupsProvider);
      return group;
    } catch (e) {
      debugPrint('[AirChat] MLS group creation failed; using legacy: $e');
      try {
        await service.deleteGroup(groupId);
      } catch (_) {}
      return null;
    }
  }

  /// The legacy path: one shared symmetric key, distributed inside each invite.
  Future<Group> _createLegacyGroup({
    required String groupId,
    required String groupName,
    required int createdAt,
    required String myUid,
    required List<String> allMembers,
    required List<String> memberUids,
  }) async {
    final groupKey = _generateGroupKey();
    final group = Group(
      id: groupId,
      name: groupName,
      memberUids: allMembers,
      createdAt: createdAt,
      groupKey: groupKey,
      keyVersion: 1, // first generation of this group key
      cryptoVersion: GroupCrypto.legacySharedKey,
    );
    await ref.read(groupDaoProvider).insertGroup(group);
    await _registerGroupWithServer(group);

    final signingKeyPair = await KeyStore.getSigningKeyPair();
    String inviteSig = '';
    if (signingKeyPair != null) {
      try {
        inviteSig = await SigningEngine().signHex(
          'group_invite|${group.id}|${allMembers.join(',')}',
          signingKeyPair,
        );
      } catch (_) {}
    }

    for (final uid in memberUids) {
      try {
        final encrypted = await encryptToOneToOne(
          uid,
          jsonEncode({
            'type': 'group_invite',
            'text': '',
            'groupId': group.id,
            'groupName': group.name,
            'memberUids': allMembers,
            'groupKey': groupKey, // encrypted per-member, never broadcast
            'keyVersion': group.keyVersion,
            'cryptoVersion': GroupCrypto.legacySharedKey,
            if (inviteSig.isNotEmpty) 'sig': inviteSig,
          }),
        );
        if (encrypted == null) continue;
        ref
            .read(websocketClientProvider(myUid))
            .sendPacket(
              recipientUid: uid,
              encryptedPayload: encrypted,
              packetId: 'grp_${const Uuid().v4()}',
            );
      } catch (_) {}
    }
    ref.invalidate(groupsProvider);
    return group;
  }

  /// Delivers an MLS Welcome to one new member over the existing encrypted 1:1
  /// channel, as a `group_invite` carrying the Welcome instead of a key.
  ///
  /// Returns whether it was actually sent. The caller treats false as "this
  /// member cannot be provisioned", which is not recoverable by retrying the
  /// same send — their identity key is unknown, so there is nothing to encrypt
  /// to.
  Future<bool> _sendMlsWelcome({
    required String recipientUid,
    required Group group,
    required Uint8List welcome,
  }) async {
    final myUid = await KeyStore.getUid() ?? '';
    try {
      final signingKeyPair = await KeyStore.getSigningKeyPair();
      String sig = '';
      if (signingKeyPair != null) {
        try {
          sig = await SigningEngine().signHex(
            'group_invite|${group.id}|${group.memberUids.join(',')}',
            signingKeyPair,
          );
        } catch (_) {}
      }
      final encrypted = await encryptToOneToOne(
        recipientUid,
        jsonEncode({
          'type': 'group_invite',
          'text': '',
          'groupId': group.id,
          'groupName': group.name,
          'memberUids': group.memberUids,
          'cryptoVersion': GroupCrypto.mls,
          'mlsWelcome': base64Encode(welcome),
          if (sig.isNotEmpty) 'sig': sig,
        }),
      );
      if (encrypted == null) return false;
      ref
          .read(websocketClientProvider(myUid))
          .sendPacket(
            recipientUid: recipientUid,
            encryptedPayload: encrypted,
            packetId: 'grp_${const Uuid().v4()}',
          );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Idempotency tokens so N survivors observing one kick don't each rotate.
  final Set<String> _rekeyedTokens = {};

  Future<void> addMembers(String groupId, List<String> newUids) async {
    final dao = ref.read(groupDaoProvider);
    final group = await dao.getGroupById(groupId);
    if (group == null) return;
    final updated = {...group.memberUids, ...newUids}.toList();

    if (group.usesMls) {
      await _mlsAddMembers(group, newUids, updated);
      return;
    }

    // Legacy: re-key on membership change, so the new key goes only to the new
    // roster.
    final newKey = _generateGroupKey();
    await dao.updateGroupKey(groupId, newKey);
    await dao.updateKeyVersion(groupId, group.keyVersion + 1);
    await dao.updateMembers(groupId, updated);
    await _registerGroupWithServer(group.copyWith(memberUids: updated));
    ref.invalidate(groupsProvider);
    await _broadcastGroupControl(
      groupId: groupId,
      type: 'group_add',
      memberUids: updated,
    );
  }

  /// Adds members to an MLS group: one Commit for the existing members and one
  /// Welcome per new member.
  Future<void> _mlsAddMembers(
    Group group,
    List<String> newUids,
    List<String> updated,
  ) async {
    final service = MlsGroupService.instance;
    final packages = <Uint8List>[];
    for (final uid in newUids) {
      final keyPackage = await fetchMlsKeyPackage(uid);
      if (keyPackage == null) return;
      packages.add(keyPackage);
    }
    try {
      final added = await service.addMembers(
        groupId: group.id,
        keyPackages: packages,
      );
      await ref.read(groupDaoProvider).updateMembers(group.id, updated);
      await _registerGroupWithServer(group.copyWith(memberUids: updated));
      // The Commit is what advances *existing* members: without it they are
      // still on the old epoch and a new message would not decrypt.
      await broadcastMlsCommit(group.id, added.commit);
      for (final uid in newUids) {
        final delivered = await _sendMlsWelcome(
          recipientUid: uid,
          group: group.copyWith(memberUids: updated),
          welcome: added.welcome,
        );
        if (!delivered) {
          // The commit has already advanced the epoch for the existing
          // members, so this cannot be undone; surface it rather than leaving
          // the new member silently unprovisioned.
          debugPrint('[AirChat] MLS welcome undeliverable to $uid');
        }
      }
      ref.invalidate(groupsProvider);
    } catch (e) {
      debugPrint('[AirChat] MLS add failed: $e');
    }
  }

  Future<void> leaveGroup(String groupId) async {
    final dao = ref.read(groupDaoProvider);
    final myUid = await KeyStore.getUid() ?? '';
    final group = await dao.getGroupById(groupId);
    if (group == null) return;
    final remaining = group.memberUids.where((u) => u != myUid).toList();
    final wasMls = group.usesMls;
    // Leaver's device: delete the group entirely (no lingering thread where
    // they could still send). Remaining members receive the kick.
    await dao.deleteGroup(groupId);

    if (wasMls) {
      // Drop the MLS state too, so the device holds no epoch secrets for a
      // group it has left.
      try {
        await MlsGroupService.instance.deleteGroup(groupId);
      } catch (_) {}
    }

    if (remaining.isNotEmpty) {
      await _registerGroupWithServer(group.copyWith(memberUids: remaining));
      await _broadcastGroupControl(
        groupId: groupId,
        type: 'group_kick',
        memberUids: remaining,
        kickedUid: myUid,
      );
    }
    ref.invalidate(groupsProvider);
  }

  /// Publishes an MLS Commit to the group channel.
  ///
  /// MLS-native addressing: a Commit is a group message, and `processMessage`
  /// on the receiving side merges it and advances the epoch. Sent as a v2
  /// envelope so a member on the legacy scheme ignores it rather than trying to
  /// parse it as a shared-key ciphertext.
  Future<void> broadcastMlsCommit(String groupId, Uint8List commit) async {
    final myUid = await KeyStore.getUid() ?? '';
    try {
      ref
          .read(websocketClientProvider(myUid))
          .sendGroupPacket(
            groupId: groupId,
            encryptedPayload: WireEnvelope(
              kind: WireEnvelope.kindMls,
              messageType: 0,
              ciphertext: commit,
            ).encode(),
            packetId: 'mls_${const Uuid().v4()}',
            senderName: '',
          );
    } catch (_) {}
  }

  /// Removes members from an MLS group, which is how access is actually revoked.
  ///
  /// Before the Commit a removed member can still read; after it, the epoch
  /// secret they hold no longer derives the group's keys. That is the whole
  /// point of doing this through MLS rather than rotating a shared key.
  Future<void> removeMlsMembers(String groupId, List<String> uids) async {
    final dao = ref.read(groupDaoProvider);
    final group = await dao.getGroupById(groupId);
    if (group == null || !group.usesMls || uids.isEmpty) return;
    try {
      final commit = await MlsGroupService.instance.removeMembers(
        groupId: groupId,
        uids: uids,
      );
      final remaining = group.memberUids
          .where((u) => !uids.contains(u))
          .toList();
      await dao.updateMembers(groupId, remaining);
      await _registerGroupWithServer(group.copyWith(memberUids: remaining));
      await broadcastMlsCommit(groupId, commit);
      ref.invalidate(groupsProvider);
    } catch (e) {
      debugPrint('[AirChat] MLS remove failed: $e');
    }
  }

  /// Registers group membership with the relay server via REST API.
  /// The relay stores groupId→memberUids in D1 so it can wake all members
  /// for group_packet sends.
  Future<void> _registerGroupWithServer(Group group) async {
    try {
      final myUid = await KeyStore.getUid();
      final signingKp = await KeyStore.getSigningKeyPair();
      if (myUid == null || myUid.isEmpty || signingKp == null) return;
      // Signed so nobody can inject members into a group they don't own.
      final signature = await SigningEngine().signHex(
        'group_register|$myUid|${group.id}|${group.memberUids.join(',')}',
        signingKp,
      );
      final uri = Uri.parse('${ApiClient.defaultBaseUrl}/api/group/register');
      await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            // No groupName: the relay stores routing state only. The name is
            // not needed to fan out a wake, and retaining it server-side was
            // the metadata leak documented in SECURITY_GROUP_CRYPTO.md §5.
            body: jsonEncode({
              'uid': myUid,
              'groupId': group.id,
              'memberUids': group.memberUids,
              'signature': signature,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[AirChat] register_group failed');
    }
  }

  Future<void> _broadcastGroupControl({
    required String groupId,
    required String type,
    required List<String> memberUids,
    String? kickedUid,
  }) async {
    final myUid = await KeyStore.getUid() ?? '';
    final signingKeyPair = await KeyStore.getSigningKeyPair();
    final group = await ref.read(groupDaoProvider).getGroupById(groupId);
    // Sign roster changes so receivers can verify the control came from a
    // member (not the relay or an outsider).
    String controlSig = '';
    if (signingKeyPair != null) {
      try {
        controlSig = await SigningEngine().signHex(
          '$type|$groupId|${memberUids.join(',')}',
          signingKeyPair,
        );
      } catch (_) {}
    }
    for (final uid in memberUids) {
      if (uid == myUid) continue;
      try {
        final encrypted = await encryptToOneToOne(
          uid,
          jsonEncode({
            'type': type,
            'text': '',
            'groupId': groupId,
            'groupName': group?.name ?? '',
            'memberUids': memberUids,
            if (group?.groupKey != null) 'groupKey': group!.groupKey,
            // Receivers reject a key-carrying control that is not newer than
            // what they hold, which is what makes rotation replay-proof.
            if (group != null) 'keyVersion': group.keyVersion,
            if (group != null) 'cryptoVersion': group.cryptoVersion,
            if (kickedUid != null) 'kickedUid': kickedUid,
            if (controlSig.isNotEmpty) 'sig': controlSig,
          }),
        );
        if (encrypted == null) continue;
        ref
            .read(websocketClientProvider(myUid))
            .sendPacket(
              recipientUid: uid,
              encryptedPayload: encrypted,
              packetId: 'grp_${const Uuid().v4()}',
            );
      } catch (_) {}
    }
  }

  /// Rotates the group key and distributes it to the current roster.
  /// Called when a kick/leave is observed (via the 'rekey' bus event).
  /// Old key is deleted locally. [token] dedupes concurrent triggers for
  /// the same membership change across N survivors.
  Future<void> rotateGroupKey(String groupId, {String? token}) async {
    if (token != null) {
      if (!_rekeyedTokens.add(token)) return;
      if (_rekeyedTokens.length > 200) _rekeyedTokens.clear();
    }
    final dao = ref.read(groupDaoProvider);
    final group = await dao.getGroupById(groupId);
    if (group == null) return;
    final newKey = _generateGroupKey();
    await dao.updateGroupKey(groupId, newKey);
    await dao.updateKeyVersion(groupId, group.keyVersion + 1);
    ref.invalidate(groupsProvider);
    await _broadcastGroupControl(
      groupId: groupId,
      type: 'group_add',
      memberUids: group.memberUids,
    );
  }
}

final groupActionsProvider = Provider((ref) => GroupActions(ref));

/// Watches for 'rekey' bus events (a kick or a departure) and revokes access.
///
/// Deterministic rotator election: the surviving member with the
/// lexicographically smallest uid acts. All survivors compute the same rule, so
/// exactly one commit (or rotation) happens — no key divergence.
///
/// * MLS groups: the elected member **removes** whoever is in the ratchet tree
///   but no longer in the roster. That is what actually revokes them.
/// * Legacy groups: it rotates the shared key, the best that construction can
///   do (and it cannot revoke a member who kept the rotated key out of the
///   fan-out — documented in SECURITY_GROUP_CRYPTO.md).
///
/// Lives for the app lifetime via keepAlive — revocation must happen even with
/// no chat screen open.
final groupRekeyWatcherProvider = Provider((ref) {
  final sub = ref.watch(refreshBusProvider).stream.listen((event) async {
    if (event.type == 'rekey' && event.chatId != null) {
      final chatId = event.chatId!;
      try {
        final myUid = await KeyStore.getUid() ?? '';
        final group = await ref.read(groupDaoProvider).getGroupById(chatId);
        if (group == null || myUid.isEmpty) return;
        if (!group.memberUids.contains(myUid)) return;
        final sorted = [...group.memberUids]..sort();
        if (sorted.first != myUid) return; // not the elected actor

        if (group.usesMls) {
          // Whoever the tree still holds but the roster no longer lists has to
          // go: they are the member whose access this event is about.
          final treeMembers = await MlsGroupService.instance.members(chatId);
          final departed = treeMembers
              .where((u) => u != myUid && !group.memberUids.contains(u))
              .toList();
          if (departed.isEmpty) return;
          await ref
              .read(groupActionsProvider)
              .removeMlsMembers(chatId, departed);
          return;
        }

        await ref
            .read(groupActionsProvider)
            .rotateGroupKey(chatId, token: 'kick:$chatId');
      } catch (_) {}
    }
  });
  ref.onDispose(() => sub.cancel());
  ref.keepAlive();
  return sub;
});

/// Re-registers every local group with the relay once per app launch.
///
/// Relay-side group membership is now *expiring* routing state rather than a
/// permanent table (SECURITY_GROUP_CRYPTO.md §5), so a group the user has not
/// touched in a long time would eventually fall out of it and stop receiving
/// wakes. Refreshing on launch keeps the groups a user actually still has
/// alive without asking the relay to remember them forever.
/// KeepAlive: this must run even with no chat screen open.
final groupMembershipRefreshProvider = Provider((ref) {
  ref.keepAlive();
  Future(() async {
    try {
      final myUid = await KeyStore.getUid() ?? '';
      if (myUid.isEmpty) return;
      final dao = ref.read(groupDaoProvider);
      final groups = await dao.getAllGroups();
      final actions = ref.read(groupActionsProvider);
      for (final group in groups) {
        // A one-member group has nobody to route to.
        if (group.memberUids.length < 2) continue;
        await actions._registerGroupWithServer(group);
      }
    } catch (_) {}
  });
  return null;
});
