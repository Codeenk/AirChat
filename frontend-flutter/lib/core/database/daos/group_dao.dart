import 'dart:convert';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../app_database.dart';
import '../../../models/group.dart';

/// Last-activity summary for a group, derived from its messages.
class GroupActivity {
  final int timestamp;
  final String preview;
  const GroupActivity({required this.timestamp, required this.preview});
}

class GroupDao {
  Future<void> insertGroup(Group group) async {
    final db = await AppDatabase.instance;
    await db.insert(
      'groups',
      group.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Group?> getGroupById(String id) async {
    final db = await AppDatabase.instance;
    final maps = await db.query(
      'groups',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Group.fromMap(maps.first);
  }

  Future<List<Group>> getAllGroups() async {
    final db = await AppDatabase.instance;
    final maps = await db.query('groups', orderBy: 'created_at DESC');
    return maps.map((m) => Group.fromMap(m)).toList();
  }

  /// Newest message per chat, keyed by chat id. Lets the home list merge
  /// groups and 1:1 threads into one time-ordered feed without N queries.
  Future<Map<String, GroupActivity>> getLastActivity() async {
    final db = await AppDatabase.instance;
    final maps = await db.rawQuery('''
      SELECT m.chat_id AS chat_id, m.text AS text, m.type AS type,
             m.timestamp AS timestamp
      FROM messages m
      JOIN (
        SELECT chat_id AS cid, MAX(timestamp) AS mt
        FROM messages GROUP BY chat_id
      ) x ON m.chat_id = x.cid AND m.timestamp = x.mt
    ''');
    final out = <String, GroupActivity>{};
    for (final row in maps) {
      final cid = row['chat_id'] as String? ?? '';
      if (cid.isEmpty) continue;
      final text = row['text'] as String? ?? '';
      final type = row['type'] as String? ?? 'text';
      out[cid] = GroupActivity(
        timestamp: row['timestamp'] as int? ?? 0,
        preview: text.isEmpty ? '\u{1F4CE} $type' : text,
      );
    }
    return out;
  }

  Future<void> updateMembers(String id, List<String> memberUids) async {
    final db = await AppDatabase.instance;
    await db.update(
      'groups',
      {'member_uids': jsonEncode(memberUids)},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateGroupKey(String id, String groupKey) async {
    final db = await AppDatabase.instance;
    await db.update(
      'groups',
      {'group_key': groupKey},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteGroup(String id) async {
    final db = await AppDatabase.instance;
    await db.delete('groups', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> incrementUnread(String id) async {
    final db = await AppDatabase.instance;
    await db.rawUpdate(
      'UPDATE groups SET unread_count = unread_count + 1 WHERE id = ?',
      [id],
    );
  }

  Future<void> resetUnread(String id) async {
    final db = await AppDatabase.instance;
    await db.update(
      'groups',
      {'unread_count': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
