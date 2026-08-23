import 'package:sqflite_sqlcipher/sqflite.dart';
import '../app_database.dart';
import '../../../models/message_payload.dart';

class MessageDao {
  Future<void> insertMessage(ChatMessage message) async {
    final db = await AppDatabase.instance;
    await db.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ChatMessage>> getMessagesForChat(String chatId) async {
    final db = await AppDatabase.instance;
    final maps = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp ASC',
    );
    return maps.map((m) => ChatMessage.fromMap(m)).toList();
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
}
