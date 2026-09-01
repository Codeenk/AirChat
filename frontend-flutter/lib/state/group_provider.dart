import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

import '../core/crypto/key_store.dart';
import '../core/database/daos/contact_dao.dart';
import '../core/database/daos/group_dao.dart';
import '../core/network/api_client.dart';
import '../models/group.dart';
import 'connection_provider.dart';

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

  /// Creates a local group, generates a shared symmetric groupKey, and fans
  /// out invites (containing the groupKey) via pairwise 1:1 wires.
  Future<Group> createGroup({
    required String name,
    required List<String> memberUids,
  }) async {
    final myUid = await KeyStore.getUid() ?? '';
    final allMembers = {myUid, ...memberUids}.toList();

    // Generate the shared symmetric group key — all members will use this
    // to encrypt/decrypt group messages. Distributed once via encrypted invites.
    final groupKey = _generateGroupKey();

    final group = Group(
      id: 'grp_${const Uuid().v4().replaceAll('-', '').substring(0, 16)}',
      name: name.trim().isEmpty ? 'Group' : name.trim(),
      memberUids: allMembers,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      groupKey: groupKey,
    );
    await ref.read(groupDaoProvider).insertGroup(group);

    // Register group membership with the relay server so it can route
    // group_packet wakes to all members.
    await _registerGroupWithServer(group);

    // Fan-out invites: one 1:1 message per member carrying the groupKey.
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
            'groupKey': groupKey, // encrypted per-member via X25519
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

    // Re-register with the server so new members get group wakes.
    await _registerGroupWithServer(group.copyWith(memberUids: updated));

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
    // Leaver's device: delete the group entirely (no lingering thread where
    // they could still send). Remaining members receive the kick.
    await dao.deleteGroup(groupId);

    // Re-register with the server (without the leaver) so they stop getting wakes.
    if (remaining.isNotEmpty) {
      await _registerGroupWithServer(group.copyWith(memberUids: remaining));
    }

    if (remaining.isNotEmpty) {
      await _broadcastGroupControl(
        groupId: groupId,
        type: 'group_kick',
        memberUids: remaining,
        kickedUid: myUid,
      );
    }
    ref.invalidate(groupsProvider);
  }

  /// Registers group membership with the relay server via REST API.
  /// The relay stores groupId→memberUids in D1 so it can wake all members
  /// for group_packet sends.
  Future<void> _registerGroupWithServer(Group group) async {
    try {
      final uri = Uri.parse('${ApiClient.defaultBaseUrl}/api/group/register');
      await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'groupId': group.id,
              'groupName': group.name,
              'memberUids': group.memberUids,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[AirChat] register_group failed: $e');
    }
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
          if (group?.groupKey != null) 'groupKey': group!.groupKey,
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
