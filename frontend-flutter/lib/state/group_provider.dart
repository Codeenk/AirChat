import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/crypto/key_store.dart';
import '../core/database/daos/contact_dao.dart';
import '../core/database/daos/group_dao.dart';
import '../models/group.dart';
import 'connection_provider.dart';

final groupDaoProvider = Provider((_) => GroupDao());

final groupsProvider = StreamProvider<List<Group>>((ref) async* {
  final dao = ref.watch(groupDaoProvider);
  yield await dao.getAllGroups();
  // Refresh is manual for now — invalidation on CUD.
});

class GroupActions {
  final Ref ref;
  GroupActions(this.ref);

  /// Creates a local group and fans out invites via pairwise 1:1 wires.
  Future<Group> createGroup({
    required String name,
    required List<String> memberUids,
  }) async {
    final myUid = await KeyStore.getUid() ?? '';
    final allMembers = {myUid, ...memberUids}.toList();
    final group = Group(
      id: 'grp_${const Uuid().v4().replaceAll('-', '').substring(0, 16)}',
      name: name.trim().isEmpty ? 'Group' : name.trim(),
      memberUids: allMembers,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await ref.read(groupDaoProvider).insertGroup(group);

    // Fan-out invites: one 1:1 message per member (same wire as any chat).
    // Reuses the existing WS path — no server group table.
    final engine = ref.read(sodiumEngineProvider);
    final myKeyPair = await KeyStore.getKeyPair();
    if (myKeyPair != null) {
      for (final uid in memberUids) {
        try {
          final contact = await ContactDao().getContactByUid(uid);
          final pubKey = contact?.identityPublicKey;
          if (pubKey == null || pubKey.isEmpty) continue;
          final recipientPub = await engine.importPublicKey(pubKey);
          final payload = {
            'type': 'group_invite',
            'text': '',
            'groupId': group.id,
            'groupName': group.name,
            'memberUids': allMembers,
          };
          final enc = await engine.encryptMessage(
            plainText: jsonEncode(payload),
            recipientPublicKey: recipientPub,
            senderKeyPair: myKeyPair,
          );
          final ws = ref.read(websocketClientProvider(myUid));
          ws.sendPacket(
            recipientUid: uid,
            encryptedPayload: enc.encode(),
            packetId: 'grp_${const Uuid().v4()}',
          );
        } catch (_) {}
      }
    }
    ref.invalidate(groupsProvider);
    return group;
  }

  Future<void> addMembers(String groupId, List<String> newUids) async {
    final dao = ref.read(groupDaoProvider);
    final group = await dao.getGroupById(groupId);
    if (group == null) return;
    final updated = {...group.memberUids, ...newUids}.toList();
    await dao.updateMembers(groupId, updated);
    ref.invalidate(groupsProvider);
    // Fan-out group_add to all (existing + new) so everyone has the new roster.
    await _broadcastGroupControl(
      groupId: groupId,
      type: 'group_add',
      memberUids: updated,
    );
  }

  Future<void> leaveGroup(String groupId) async {
    final dao = ref.read(groupDaoProvider);
    final myUid = await KeyStore.getUid() ?? '';
    final group = await dao.getGroupById(groupId);
    if (group == null) return;
    final remaining = group.memberUids.where((u) => u != myUid).toList();
    if (remaining.isEmpty) {
      await dao.deleteGroup(groupId);
    } else {
      await dao.updateMembers(groupId, remaining);
      await _broadcastGroupControl(
        groupId: groupId,
        type: 'group_kick',
        memberUids: remaining,
        kickedUid: myUid,
      );
    }
    ref.invalidate(groupsProvider);
  }

  Future<void> _broadcastGroupControl({
    required String groupId,
    required String type,
    required List<String> memberUids,
    String? kickedUid,
  }) async {
    final myUid = await KeyStore.getUid() ?? '';
    final engine = ref.read(sodiumEngineProvider);
    final myKeyPair = await KeyStore.getKeyPair();
    if (myKeyPair == null) return;
    final group = await ref.read(groupDaoProvider).getGroupById(groupId);
    for (final uid in memberUids) {
      if (uid == myUid) continue;
      try {
        final contact = await ContactDao().getContactByUid(uid);
        final pubKey = contact?.identityPublicKey;
        if (pubKey == null || pubKey.isEmpty) continue;
        final recipientPub = await engine.importPublicKey(pubKey);
        final payload = {
          'type': type,
          'text': '',
          'groupId': groupId,
          'groupName': group?.name ?? '',
          'memberUids': memberUids,
          if (kickedUid != null) 'kickedUid': kickedUid,
        };
        final enc = await engine.encryptMessage(
          plainText: jsonEncode(payload),
          recipientPublicKey: recipientPub,
          senderKeyPair: myKeyPair,
        );
        ref
            .read(websocketClientProvider(myUid))
            .sendPacket(
              recipientUid: uid,
              encryptedPayload: enc.encode(),
              packetId: 'grp_${const Uuid().v4()}',
            );
      } catch (_) {}
    }
  }
}

final groupActionsProvider = Provider((ref) => GroupActions(ref));
