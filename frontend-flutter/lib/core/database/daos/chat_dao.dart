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

  Future<ChatThread?> getChatById(String chatId) async {
    final db = await AppDatabase.instance;
    final maps = await db.query('chat_threads', where: 'id = ?', whereArgs: [chatId]);
    if (maps.isNotEmpty) return ChatThread.fromMap(maps.first);
    return null;
  }
}
