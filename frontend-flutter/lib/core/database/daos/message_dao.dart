import 'package:sqflite_sqlcipher/sqflite.dart';
import '../app_database.dart';
import '../../../models/message_payload.dart';

class MessageDao {
  static const int _defaultPageSize = 50;

  Future<void> insertMessage(ChatMessage message) async {
    final db = await AppDatabase.instance;
    await db.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns the latest [limit] messages for a chat, ordered oldest-first.
  /// Used for initial page load and "load more" pagination.
  Future<List<ChatMessage>> getMessagesForChat(
    String chatId, {
    int limit = _defaultPageSize,
    int offset = 0,
  }) async {
    final db = await AppDatabase.instance;
    final maps = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    // Reverse so oldest-first for display (query was DESC for correct offset).
    return maps.reversed.map((m) => ChatMessage.fromMap(m)).toList();
  }

  /// Total message count for a chat — used to decide if "load more" is available.
  Future<int> getMessageCount(String chatId) async {
    final db = await AppDatabase.instance;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM messages WHERE chat_id = ?',
      [chatId],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  Future<void> updateMessageStatus(String messageId, String status) async {
    final db = await AppDatabase.instance;
    await db.update(
      'messages',
      {'status': status},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<List<ChatMessage>> getPendingMessages() async {
    final db = await AppDatabase.instance;
    final maps = await db.query(
      'messages',
      where: "status IN ('sending','failed') AND is_me = 1",
    );
    return maps.map((m) => ChatMessage.fromMap(m)).toList();
  }

  Future<ChatMessage?> getMessageById(String id) async {
    final db = await AppDatabase.instance;
    final maps = await db.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    if (maps.isEmpty) return null;
    return ChatMessage.fromMap(maps.first);
  }

  Future<void> deleteMessage(String id) async {
    final db = await AppDatabase.instance;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }
}
