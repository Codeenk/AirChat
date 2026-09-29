import '../app_database.dart';
import '../../../models/contact.dart';

class ContactDao {
  /// Inserts or refreshes a contact.
  ///
  /// Deliberately **not** `ConflictAlgorithm.replace`. This runs whenever the
  /// peer's name or keys are (re)read from the directory — routinely, on almost
  /// every launch — and `replace` is a DELETE+INSERT that would silently wipe the
  /// user's verification each time. A key change must instead be *detected*, by
  /// `Contact.isVerified` comparing the stored `verified_*` keys against the live
  /// ones, so those columns are never written here.
  ///
  /// `signing_public_key` uses COALESCE: a caller that does not know the value
  /// (an older QR code, a partial refresh) must not erase one already on file,
  /// because losing it would make a verified contact read as "key changed".
  Future<void> insertContact(Contact contact) async {
    final db = await AppDatabase.instance;
    await db.rawInsert(
      '''
      INSERT INTO contacts
        (uid, username, identity_public_key, signing_public_key, created_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(uid) DO UPDATE SET
        username = excluded.username,
        identity_public_key = excluded.identity_public_key,
        signing_public_key = COALESCE(excluded.signing_public_key, contacts.signing_public_key)
      ''',
      [
        contact.uid,
        contact.username,
        contact.identityPublicKey,
        Contact.normalizeSigningKey(contact.signingPublicKey),
        contact.createdAt,
      ],
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

  /// Records that the user compared the safety number for [uid] and it matched.
  /// Stores the keys they were looking at, so a later change is detectable.
  Future<void> markVerified(
    String uid, {
    required String identityKey,
    required String signingKey,
  }) async {
    final db = await AppDatabase.instance;
    await db.update(
      'contacts',
      {
        'verified_identity_key': identityKey,
        'verified_signing_key': Contact.normalizeSigningKey(signingKey),
        'verified_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'uid = ?',
      whereArgs: [uid],
    );
  }

  /// Revokes verification (user said "this no longer matches me").
  Future<void> clearVerification(String uid) async {
    final db = await AppDatabase.instance;
    await db.update(
      'contacts',
      {
        'verified_identity_key': null,
        'verified_signing_key': null,
        'verified_at': null,
      },
      where: 'uid = ?',
      whereArgs: [uid],
    );
  }
}
