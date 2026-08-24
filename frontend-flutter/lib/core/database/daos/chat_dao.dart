import 'package:sqflite_sqlcipher/sqflite.dart';
import '../app_database.dart';
import '../../../models/chat_thread.dart';

class ChatDao {
  Future<void> insertOrUpdateChat(ChatThread chat) async {
    final db = await AppDatabase.instance;
    await db.insert(
      'chat_threads',
      chat.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ChatThread>> getAllChats() async {
    final db = await AppDatabase.instance;
    final maps = await db.query('chat_threads', orderBy: 'last_message_time DESC');
    return maps.map((m) => ChatThread.fromMap(m)).toList();
  }

  /// Single JOIN query that embeds contact username — eliminates N+1
  /// FutureBuilder queries in the home chat list.
  Future<List<ChatThread>> getAllChatsWithContacts() async {
    final db = await AppDatabase.instance;
    final maps = await db.rawQuery('''
      SELECT ct.*, c.username as contact_username
      FROM chat_threads ct
      LEFT JOIN contacts c ON ct.contact_uid = c.uid
      ORDER BY ct.last_message_time DESC
    ''');
    return maps.map((m) => ChatThread.fromMap(m)).toList();
  }

  /// Upsert that refreshes only the preview fields, preserving unread_count.
  /// (A blind REPLACE would reset the badge to 0 on every incoming message.)
  Future<void> updatePreviewPreservingUnread(ChatThread chat) async {
    final db = await AppDatabase.instance;
    await db.rawInsert('''
      INSERT INTO chat_threads (id, contact_uid, last_message, last_message_time, unread_count)
      VALUES (?, ?, ?, ?, 0)
      ON CONFLICT(id) DO UPDATE SET
        last_message = excluded.last_message,
        last_message_time = excluded.last_message_time
    ''', [chat.id, chat.contactUid, chat.lastMessage, chat.lastMessageTime]);
  }

  Future<ChatThread?> getChatById(String chatId) async {
    final db = await AppDatabase.instance;
    final maps = await db.query('chat_threads', where: 'id = ?', whereArgs: [chatId]);
    if (maps.isNotEmpty) return ChatThread.fromMap(maps.first);
    return null;
  }

  /// Bump the unread badge for this chat (incoming message while not open).
  Future<void> incrementUnread(String chatId) async {
    final db = await AppDatabase.instance;
    await db.rawUpdate(
      'UPDATE chat_threads SET unread_count = unread_count + 1 WHERE id = ?',
      [chatId],
    );
  }

  /// Clear the unread badge (chat opened).
  Future<void> resetUnread(String chatId) async {
    final db = await AppDatabase.instance;
    await db.update(
      'chat_threads',
      {'unread_count': 0},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }
}
