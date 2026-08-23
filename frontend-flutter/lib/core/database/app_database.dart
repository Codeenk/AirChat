import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqlite_api.dart' show OpenDatabaseOptions;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart' show databaseFactoryFfiWeb;
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../crypto/key_store.dart';

class AppDatabase {
  static Database? _database;

  static Future<Database> get instance async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final masterKey = await KeyStore.getOrCreateDatabaseMasterKey();

    if (kIsWeb) {
      // Web: sqlite3.wasm-backed factory (SQLCipher unavailable in wasm).
      return await databaseFactoryFfiWeb.openDatabase(
        '/airchat/airchat_web.db',
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        ),
      );
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final path = join(docsDir.path, 'airchat_encrypted.db');

    return await openDatabase(
      path,
      password: masterKey,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE contacts (
        uid TEXT PRIMARY KEY,
        username TEXT NOT NULL,
        identity_public_key TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE chat_threads (
        id TEXT PRIMARY KEY,
        contact_uid TEXT NOT NULL,
        last_message TEXT,
        last_message_time INTEGER,
        unread_count INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        sender_uid TEXT NOT NULL,
        recipient_uid TEXT NOT NULL,
        text TEXT NOT NULL,
        media_key TEXT,
        secret_key_hex TEXT,
        nonce_hex TEXT,
        type TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_me INTEGER NOT NULL,
        status TEXT NOT NULL,
        reply_to_id TEXT,
        reply_text TEXT,
        reply_type TEXT,
        reply_is_me INTEGER
      )
    ''');
  }

  static Future<void> _onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v2: quoted-reply columns on messages (denormalized reply snapshot).
      await db.execute('ALTER TABLE messages ADD COLUMN reply_to_id TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN reply_text TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN reply_type TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN reply_is_me INTEGER');
    }
  }

  static Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
