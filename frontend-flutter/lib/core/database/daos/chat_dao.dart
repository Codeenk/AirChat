import '../app_database.dart';
import '../../../models/chat_thread.dart';

class ChatDao {
  /// Upserts the preview fields without disturbing anything the caller did not
  /// set.
  ///
  /// The previous implementation used `ConflictAlgorithm.replace`, which is a
  /// DELETE followed by an INSERT: every outgoing message therefore reset the
  /// unread badge to 0 *and* would have reset this chat back to the legacy
  /// scheme, silently downgrading a chat that had already established a
  /// Double Ratchet session. An explicit upsert preserves both. The ratchet
  /// version is only ever advanced through [setCryptoVersion].
  Future<void> insertOrUpdateChat(ChatThread chat) async {
    final db = await AppDatabase.instance;
    await db.rawInsert(
      '''
      INSERT INTO chat_threads (id, contact_uid, last_message, last_message_time, unread_count, crypto_version)
      VALUES (?, ?, ?, ?, 0, ?)
      ON CONFLICT(id) DO UPDATE SET
        contact_uid = excluded.contact_uid,
        last_message = excluded.last_message,
        last_message_time = excluded.last_message_time
    ''',
      [
        chat.id,
        chat.contactUid,
        chat.lastMessage,
        chat.lastMessageTime,
        chat.cryptoVersion,
      ],
    );
  }

  /// Records which scheme this chat uses — see [ChatCrypto].
  ///
  /// Called when a chat first establishes a Double Ratchet session (either
  /// side), and when a message arrives that proves the peer is on it.
  Future<void> setCryptoVersion(String chatId, int cryptoVersion) async {
    final db = await AppDatabase.instance;
    await db.update(
      'chat_threads',
      {'crypto_version': cryptoVersion},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  /// The scheme this chat uses, or null when no thread row exists yet.
  Future<int?> getCryptoVersion(String chatId) async {
    final db = await AppDatabase.instance;
    final maps = await db.query(
      'chat_threads',
      columns: ['crypto_version'],
      where: 'id = ?',
      whereArgs: [chatId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return maps.first['crypto_version'] as int?;
  }

  Future<List<ChatThread>> getAllChats() async {
    final db = await AppDatabase.instance;
    final maps = await db.query(
      'chat_threads',
      orderBy: 'last_message_time DESC',
    );
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
    await db.rawInsert(
      '''
      INSERT INTO chat_threads (id, contact_uid, last_message, last_message_time, unread_count)
      VALUES (?, ?, ?, ?, 0)
      ON CONFLICT(id) DO UPDATE SET
        last_message = excluded.last_message,
        last_message_time = excluded.last_message_time
    ''',
      [chat.id, chat.contactUid, chat.lastMessage, chat.lastMessageTime],
    );
  }

  Future<ChatThread?> getChatById(String chatId) async {
    final db = await AppDatabase.instance;
    final maps = await db.query(
      'chat_threads',
      where: 'id = ?',
      whereArgs: [chatId],
    );
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
