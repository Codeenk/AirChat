import 'package:sqflite_sqlcipher/sqflite.dart';

import '../app_database.dart';
import '../../../models/contact.dart';

class ContactDao {
  Future<void> insertContact(Contact contact) async {
    final db = await AppDatabase.instance;
    await db.insert(
      'contacts',
      contact.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Contact>> getAllContacts() async {
    final db = await AppDatabase.instance;
    final maps = await db.query('contacts', orderBy: 'username ASC');
    return maps.map((m) => Contact.fromMap(m)).toList();
  }

  Future<Contact?> getContactByUid(String uid) async {
    final db = await AppDatabase.instance;
    final maps = await db.query('contacts', where: 'uid = ?', whereArgs: [uid]);
    if (maps.isNotEmpty) return Contact.fromMap(maps.first);
    return null;
  }
}
