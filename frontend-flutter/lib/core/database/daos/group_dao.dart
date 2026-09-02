import 'dart:convert';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../app_database.dart';
import '../../../models/group.dart';

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
    await db.rawUpdate('UPDATE groups SET unread_count = unread_count + 1 WHERE id = ?', [id]);
  }

  Future<void> resetUnread(String id) async {
    final db = await AppDatabase.instance;
    await db.update('groups', {'unread_count': 0}, where: 'id = ?', whereArgs: [id]);
  }
}
