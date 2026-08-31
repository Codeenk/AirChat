import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common/sqlite_api.dart' show OpenDatabaseOptions;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart'
    show databaseFactoryFfiWeb;
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
          version: 4,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        ),
      );
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final path = join(docsDir.path, 'airchat_encrypted.db');

    try {
      return await openDatabase(
        path,
        password: masterKey,
        version: 4,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('file is not a database') ||
          msg.contains('not a database') ||
          msg.contains('database disk image is malformed') ||
          msg.contains('file is encrypted or is not a database')) {
        await _deleteDbFile(path);
        return await openDatabase(
          path,
          password: masterKey,
          version: 4,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        );
      }
      rethrow;
    }
  }

  static Future<void> _deleteDbFile(String path) async {
    try {
      final file = io.File(path);
      if (await file.exists()) await file.delete();
      for (final suffix in ['-journal', '-wal', '-shm']) {
        final extra = io.File('$path$suffix');
        if (await extra.exists()) await extra.delete();
      }
    } catch (_) {}
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
    await db.execute(
      'CREATE INDEX idx_chat_threads_time ON chat_threads(last_message_time DESC)',
    );

    await db.execute('''
      CREATE TABLE groups (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        member_uids TEXT NOT NULL,
        created_at INTEGER NOT NULL
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
        reply_is_me INTEGER,
        group_id TEXT,
        group_sender_name TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_messages_chat_time ON messages(chat_id, timestamp ASC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_group ON messages(group_id, timestamp ASC)',
    );
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      // v2: quoted-reply columns — idempotent for crash-recovery (ALTER has no IF NOT EXISTS).
      for (final sql in [
        'ALTER TABLE messages ADD COLUMN reply_to_id TEXT',
        'ALTER TABLE messages ADD COLUMN reply_text TEXT',
        'ALTER TABLE messages ADD COLUMN reply_type TEXT',
        'ALTER TABLE messages ADD COLUMN reply_is_me INTEGER',
      ]) {
        try {
          await db.execute(sql);
        } catch (e) {
          if (!e.toString().toLowerCase().contains('duplicate column')) rethrow;
        }
      }
    }
    if (oldVersion < 3) {
      // v3: performance indexes for chat_id+timestamp and thread ordering.
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_messages_chat_time ON messages(chat_id, timestamp ASC)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_chat_threads_time ON chat_threads(last_message_time DESC)',
      );
    }
    if (oldVersion < 4) {
      // v4: groups + group columns on messages (all nullable — 1:1 flows untouched).
      await db.execute('''
        CREATE TABLE IF NOT EXISTS groups (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          member_uids TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');
      for (final sql in [
        'ALTER TABLE messages ADD COLUMN group_id TEXT',
        'ALTER TABLE messages ADD COLUMN group_sender_name TEXT',
      ]) {
        try {
          await db.execute(sql);
        } catch (e) {
          if (!e.toString().toLowerCase().contains('duplicate column')) rethrow;
        }
      }
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_messages_group ON messages(group_id, timestamp ASC)',
      );
    }
  }

  static Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
