import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

// `PublicKey` and `PrivateKey` exist in both packages with different meanings,
// so cryptography's are hidden: this file wants libsignal's protocol keys, and
// from cryptography it only takes the app's X25519 key pair.
import 'package:cryptography/cryptography.dart' hide PublicKey;
import 'package:libsignal/libsignal.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:synchronized/synchronized.dart';

import '../crash/crash_reporter.dart';
import '../database/app_database.dart';
import 'key_store.dart';
import 'wire_envelope.dart';

/// A peer's published libsignal prekey bundle, as it travels over the relay.
///
/// Every field is public key material the owner chose to publish. The relay
/// carries this verbatim and never parses it (see
/// `backend-worker/src/db/key_packages.ts`).
class RatchetBundle {
  /// Bundle format version. Bumping it is how a future change to this shape
  /// becomes distinguishable from the current one.
  static const int version = 1;

  final int registrationId;
  final int deviceId;
  final Uint8List identityKey;
  final int signedPreKeyId;
  final Uint8List signedPreKey;
  final Uint8List signedPreKeySignature;
  final int kyberPreKeyId;
  final Uint8List kyberPreKey;
  final Uint8List kyberPreKeySignature;

  /// This peer's sealed-sender delivery tag, or null when they are on a build
  /// that predates sealed delivery.
  ///
  /// It rides *inside* this bundle rather than being published in the identity
  /// directory on purpose. The relay stores bundles as opaque blobs it never
  /// parses, so the relay cannot read the tag and therefore cannot build the
  /// `uid <-> tag` join that would put the social graph back together. A public
  /// directory field would have handed it over directly.
  ///
  /// Null is not an error: it means "this peer cannot be sealed to yet", and
  /// the caller falls back to the legacy named transport.
  final String? deliveryTag;

  const RatchetBundle({
    required this.registrationId,
    required this.deviceId,
    required this.identityKey,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    required this.kyberPreKeyId,
    required this.kyberPreKey,
    required this.kyberPreKeySignature,
    this.deliveryTag,
  });

  String encode() => jsonEncode({
    'v': version,
    'reg': registrationId,
    'dev': deviceId,
    'id': base64Encode(identityKey),
    'spkId': signedPreKeyId,
    'spk': base64Encode(signedPreKey),
    'spkSig': base64Encode(signedPreKeySignature),
    'kybId': kyberPreKeyId,
    'kyb': base64Encode(kyberPreKey),
    'kybSig': base64Encode(kyberPreKeySignature),
    if (deliveryTag != null) 'dt': deliveryTag,
  });

  /// Parses a published bundle, or returns null when it is not one we can use.
  ///
  /// A null here is not an error condition: it is how "this peer cannot speak
  /// the ratchet" is represented, and the caller falls back to the legacy path.
  static RatchetBundle? tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['v'] != version) return null;
      return RatchetBundle(
        registrationId: decoded['reg'] as int,
        deviceId: decoded['dev'] as int,
        identityKey: base64Decode(decoded['id'] as String),
        signedPreKeyId: decoded['spkId'] as int,
        signedPreKey: base64Decode(decoded['spk'] as String),
        signedPreKeySignature: base64Decode(decoded['spkSig'] as String),
        kyberPreKeyId: decoded['kybId'] as int,
        kyberPreKey: base64Decode(decoded['kyb'] as String),
        kyberPreKeySignature: base64Decode(decoded['kybSig'] as String),
        deliveryTag: decoded['dt'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  PreKeyBundle toSignalBundle() => PreKeyBundle(
    registrationId: registrationId,
    deviceId: deviceId,
    // No one-time pre-key: this device publishes one *last-resort* signed
    // pre-key and one last-resort Kyber pre-key instead of managing a pool it
    // cannot replenish while offline. The initial handshake is therefore
    // X3DH/PQXDH without an OPK — one fewer contribution to the first
    // message's secrecy, and nothing to the ratchet that follows, which is
    // where the forward secrecy for the conversation actually comes from.
    signedPreKeyId: signedPreKeyId,
    signedPreKeyPublic: signedPreKey.toList(),
    signedPreKeySignature: signedPreKeySignature.toList(),
    identityKey: identityKey.toList(),
    kyberPreKeyId: kyberPreKeyId,
    kyberPreKeyPublic: kyberPreKey.toList(),
    kyberPreKeySignature: kyberPreKeySignature.toList(),
  );
}

/// 1:1 forward secrecy, via the Signal Protocol's Double Ratchet.
///
/// ## What this replaces
///
/// The legacy 1:1 path encrypts to the recipient's *long-term* X25519 key with
/// a fresh ephemeral sender key. That gives key freshness, not forward secrecy:
/// the recipient opens every message with a key that never changes, so one
/// compromise of that key exposes all past and future messages
/// (SECURITY_DESIGN.md §3.1). The Double Ratchet advances both a DH ratchet and
/// a symmetric ratchet per message, so a compromised key covers one message.
///
/// ## Identity
///
/// It uses **the same X25519 identity key the app already has**, imported as
/// the Signal identity key pair. That is deliberate: the safety number the user
/// compares covers that key, so the number they verified is the number that
/// authenticates the ratchet. Minting a separate Signal identity would leave
/// the ratchet identity outside the safety number entirely.
///
/// If the import cannot be shown to reproduce the same public key, the service
/// reports itself unavailable rather than falling back to a fresh identity — a
/// silent second identity would break exactly that guarantee.
///
/// ## The store contract this must satisfy
///
/// `SessionStore` documents two requirements that are silent failures when
/// missed, and both are honoured here:
///
///  * **Durable before release.** A session record *is* the ratchet, and the
///    next message's key is derived from it deterministically, so a write that
///    is lost rewinds the ratchet and reuses a message key. Every store write
///    runs inside its own SQLite transaction, committed before the callback
///    returns and therefore before libsignal hands back the ciphertext or the
///    plaintext.
///  * **Serialized per address.** The load → ratchet → store cycle is one
///    critical section; two concurrent sends for one peer would both load the
///    same record and derive the same key. Every operation runs under a lock
///    keyed by peer uid (see [_lockFor]).
class RatchetSession {
  RatchetSession({
    Future<Database> Function()? database,
    Future<SimpleKeyPair?> Function()? identityKeyPair,
    Future<String?> Function()? uid,
  }) : _database = database ?? (() => AppDatabase.instance),
       _identityKeyPairReader = identityKeyPair ?? KeyStore.getKeyPair,
       _uidReader = uid ?? KeyStore.getUid;

  /// The app-wide instance. Tests construct their own with an in-memory
  /// database and an ephemeral identity.
  static final RatchetSession instance = RatchetSession();

  final Future<Database> Function() _database;
  final Future<SimpleKeyPair?> Function() _identityKeyPairReader;
  final Future<String?> Function() _uidReader;

  /// Signal uses one device per uid in this app, so every address is device 1.
  static const int deviceId = 1;

  /// Curve25519 public keys carry a one-byte type prefix in libsignal's
  /// serialization (`0x05` = DJB). Our stored identity key is the raw 32 bytes,
  /// so this is prepended when importing and stripped when comparing.
  static const int _djbKeyType = 0x05;

  // ─── storage keys ───
  static const String _kindSession = 'session';
  static const String _kindIdentity = 'identity';
  static const String _kindPreKey = 'pre';
  static const String _kindSignedPreKey = 'spk';
  static const String _kindKyberPreKey = 'kyber';
  static const String _kindKyberUsed = 'kyber_used';
  static const String _kindPeer = 'peer';

  static const String _metaRegistrationId = 'registration_id';
  static const String _metaSignedPreKeyId = 'signed_prekey_id';
  static const String _metaKyberPreKeyId = 'kyber_prekey_id';

  /// Which identity signed the stored pre-keys.
  ///
  /// Pre-keys carry a signature made *by the identity key*, so pre-keys signed
  /// by a different identity make every published bundle fail verification at
  /// the peer — silently, as far as this device is concerned. Recording the
  /// signing identity is what lets a changed identity (a reinstall, or a
  /// restored backup with a fresh key) be detected and the pre-keys rebuilt
  /// instead of republished.
  static const String _metaPreKeyIdentity = 'prekey_identity';

  /// Prefix byte on a cached peer row: present (key follows) or absent.
  static const int _peerHasKey = 1;
  static const int _peerNoKey = 0;

  /// libsignal requires explicit initialization before any call.
  bool _ready = false;
  bool _initTried = false;
  Future<void>? _initializing;

  IdentityKeyPair? _identity;
  int? _registrationId;
  String? _localName;

  /// One lock per peer address. Deliberately not per-cipher-instance — the
  /// critical section spans the whole load/ratchet/store cycle, so the lock has
  /// to outlive any single call.
  final Map<String, Lock> _locks = {};

  Lock _lockFor(String peerUid) => _locks.putIfAbsent(peerUid, Lock.new);

  /// Runs [op] with the per-peer lock held.
  Future<T> _serialized<T>(String peerUid, Future<T> Function() op) =>
      _lockFor(peerUid).synchronized(op);

  /// Whether the ratchet can be used at all on this device.
  bool get available => _ready;

  // ─── lifecycle ───

  /// Initializes libsignal and loads this device's ratchet identity.
  ///
  /// Idempotent and safe to call on every launch; concurrent callers share one
  /// attempt. A failure leaves [available] false and the app on the legacy
  /// path — never a half-initialized state.
  Future<void> ensureReady() async {
    if (_ready || _initTried) return;
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await LibSignal.init();
      _localName ??= await _uidReader();
      if (_localName == null || _localName!.isEmpty) return;

      final identity = await _deriveIdentityKeyPair();
      if (identity == null) {
        CrashReporter.recordError(
          error: 'ratchet identity not importable; staying on legacy 1:1',
          source: 'ratchet-init',
        );
        return;
      }
      _identity = identity;
      _registrationId = await _loadOrCreateRegistrationId();
      await _ensureLastResortPreKeys(identity);
      _ready = true;
    } catch (e) {
      CrashReporter.recordError(
        error: 'ratchet init failed: $e',
        source: 'ratchet-init',
      );
    } finally {
      _initTried = true;
    }
  }

  /// Overrides the local protocol name. Production reads it from the keystore;
  /// tests set it directly.
  Future<void> setLocalName(String uid) async {
    _localName = uid;
  }

  /// Imports the app's existing X25519 identity key pair as the Signal
  /// identity, after checking that the private half really reproduces the
  /// public half the rest of the app publishes.
  Future<IdentityKeyPair?> _deriveIdentityKeyPair() async {
    final keyPair = await _identityKeyPairReader();
    if (keyPair == null) return null;
    try {
      final privateBytes = await keyPair.extractPrivateKeyBytes();
      final publicBytes = (await keyPair.extractPublicKey()).bytes;
      if (privateBytes.length != 32 || publicBytes.length != 32) return null;

      final privateKey = PrivateKey.deserialize(bytes: privateBytes);
      final expected = Uint8List.fromList([_djbKeyType, ...publicBytes]);
      final derived = privateKey.getPublicKey().serialize();
      if (!_bytesEqual(derived, expected)) return null;

      return IdentityKeyPair.fromKeys(
        privateKey: privateKey,
        publicKey: PublicKey.deserialize(bytes: expected),
      );
    } catch (_) {
      return null;
    }
  }

  /// Registration id: a random value chosen once per install and stored in the
  /// encrypted database, so it is as durable as the sessions referencing it.
  Future<int> _loadOrCreateRegistrationId() async {
    final stored = await _readMeta(_metaRegistrationId);
    if (stored != null) {
      final parsed = int.tryParse(stored);
      if (parsed != null) return parsed;
    }
    final id = 1 + _randomInt(16380);
    await _writeMeta(_metaRegistrationId, '$id');
    return id;
  }

  /// Generates the *last-resort* signed pre-key and Kyber pre-key if absent.
  ///
  /// Last-resort means they are reused rather than burned, which is what makes
  /// session setup possible for a device that is offline when a peer wants to
  /// start a conversation. The cost is that the first message of a conversation
  /// is not additionally protected by a one-time key; subsequent messages are
  /// protected by the ratchet.
  Future<void> _ensureLastResortPreKeys(IdentityKeyPair identity) async {
    final identityId = base64Encode(identity.publicKey);
    if (await _readMeta(_metaPreKeyIdentity) != identityId) {
      // The signing identity changed, so everything signed by the previous one
      // is now unusable — regenerate rather than publish a bundle no peer can
      // verify.
      await _clearKind(_kindSignedPreKey);
      await _clearKind(_kindKyberPreKey);
      await _deleteMeta(_metaSignedPreKeyId);
      await _deleteMeta(_metaKyberPreKeyId);
      await _writeMeta(_metaPreKeyIdentity, identityId);
    }

    final timestamp = BigInt.from(DateTime.now().millisecondsSinceEpoch);

    if (await _readMeta(_metaSignedPreKeyId) == null) {
      final id = 1 + _randomInt(0xFFFFFF);
      final privateKey = PrivateKey.generate();
      final publicKey = privateKey.getPublicKey();
      final signature = identity.sign(message: publicKey.serialize().toList());
      final record = SignedPreKeyRecord(
        id: id,
        timestamp: timestamp,
        publicKey: publicKey,
        privateKey: privateKey,
        signature: signature.toList(),
      );
      await _storeBlob(_kindSignedPreKey, '$id', record.serialize());
      await _writeMeta(_metaSignedPreKeyId, '$id');
    }

    if (await _readMeta(_metaKyberPreKeyId) == null) {
      final id = 1 + _randomInt(0xFFFFFF);
      final keyPair = KyberKeyPair.generate();
      final publicKey = keyPair.getPublicKey();
      final signature = identity.sign(message: publicKey.serialize().toList());
      final record = KyberPreKeyRecord.create(
        id: id,
        timestamp: timestamp,
        keyPair: keyPair,
        signature: signature.toList(),
      );
      await _storeBlob(_kindKyberPreKey, '$id', record.serialize());
      await _writeMeta(_metaKyberPreKeyId, '$id');
    }
  }

  // ─── publishing ───

  /// This device's bundle, ready to hand to the relay, or null when the ratchet
  /// is unavailable.
  ///
  /// Built by deserializing the stored records rather than from in-memory
  /// copies, so what is published is exactly what this device can still open.
  Future<String?> localBundlePayload() async {
    await ensureReady();
    final identity = _identity;
    final registrationId = _registrationId;
    if (!_ready || identity == null || registrationId == null) return null;
    try {
      final signedId = int.parse((await _readMeta(_metaSignedPreKeyId))!);
      final kyberId = int.parse((await _readMeta(_metaKyberPreKeyId))!);
      final signedBlob = await _loadBlob(_kindSignedPreKey, '$signedId');
      final kyberBlob = await _loadBlob(_kindKyberPreKey, '$kyberId');
      if (signedBlob == null || kyberBlob == null) return null;

      final signed = SignedPreKeyRecord.deserialize(bytes: signedBlob);
      final kyber = KyberPreKeyRecord.deserialize(bytes: kyberBlob);

      return RatchetBundle(
        registrationId: registrationId,
        deviceId: deviceId,
        identityKey: identity.publicKey,
        signedPreKeyId: signed.id(),
        signedPreKey: Uint8List.fromList(signed.publicKey()),
        signedPreKeySignature: Uint8List.fromList(signed.signature()),
        kyberPreKeyId: kyber.id(),
        kyberPreKey: kyber.getPublicKey().serialize(),
        kyberPreKeySignature: Uint8List.fromList(kyber.signature()),
      ).encode();
    } catch (e) {
      CrashReporter.recordError(
        error: 'bundle build failed: $e',
        source: 'ratchet-bundle',
      );
      return null;
    }
  }

  /// The identity key this device's ratchet authenticates, base64 — the same
  /// value the directory holds as `identity_public_key`, and the value the
  /// safety number covers.
  Future<String?> localIdentityKeyBase64() async {
    await ensureReady();
    final identity = _identity;
    if (identity == null) return null;
    // Strip the libsignal type prefix to get the app's 32-byte key back.
    return base64Encode(identity.publicKey.sublist(1));
  }

  // ─── peer capability cache ───

  /// Remembers that [peerUid] published [identityKeyBase64], or that it
  /// published nothing (`null`), so a conversation does not re-fetch a bundle
  /// on every message.
  Future<void> rememberPeer(String peerUid, String? identityKeyBase64) async {
    final keyBytes = identityKeyBase64 == null
        ? const <int>[_peerNoKey]
        : <int>[_peerHasKey, ...utf8.encode(identityKeyBase64)];
    await _storeBlob(_kindPeer, peerUid, Uint8List.fromList(keyBytes));
  }

  /// Cached peer capability: a base64 identity key, `''` for "checked, has
  /// none", or `null` for "never checked". The distinction matters — only the
  /// third value justifies a network fetch.
  Future<String?> cachedPeerIdentity(String peerUid) async {
    final blob = await _loadBlob(_kindPeer, peerUid);
    if (blob == null || blob.isEmpty) return null;
    if (blob[0] == _peerNoKey) return '';
    return utf8.decode(blob.sublist(1));
  }

  // ─── sessions ───

  /// Whether a session with [peerUid] already exists locally.
  Future<bool> hasSession(String peerUid) async {
    await ensureReady();
    if (!_ready) return false;
    final blob = await _loadBlob(_kindSession, _ref(peerUid));
    return blob != null && blob.isNotEmpty;
  }

  /// Establishes a session from [bundlePayload] if one does not exist yet.
  ///
  /// Idempotent: calling it on an existing session is a no-op, which is what
  /// keeps a re-published bundle from rewinding a live ratchet.
  Future<bool> ensureSession(String peerUid, String bundlePayload) =>
      _serialized(peerUid, () async {
        await ensureReady();
        if (!_ready) return false;
        if (await hasSession(peerUid)) return true;
        final bundle = RatchetBundle.tryDecode(bundlePayload);
        if (bundle == null) return false;
        try {
          final builder = SessionBuilder(
            localAddress: ProtocolAddress(
              name: _localName!,
              deviceId: deviceId,
            ),
            sessionStore: _stores,
            identityKeyStore: _stores,
          );
          await builder.processPreKeyBundle(
            ProtocolAddress(name: peerUid, deviceId: deviceId),
            bundle.toSignalBundle(),
          );
          return true;
        } catch (e) {
          CrashReporter.recordError(
            error: 'session build failed for $peerUid: $e',
            source: 'ratchet-session',
          );
          return false;
        }
      });

  /// Encrypts [plaintext] for [peerUid] on the ratchet.
  ///
  /// Throws when there is no session — the caller must have established one
  /// from the peer's bundle first, so a missing session is a programming error,
  /// not a reason to silently fall back to the legacy path (which would turn
  /// any failure into a downgrade).
  Future<WireEnvelope> encrypt(String peerUid, String plaintext) =>
      _serialized(peerUid, () async {
        await ensureReady();
        final cipher = _cipher();
        final message = await cipher.encrypt(
          ProtocolAddress(name: peerUid, deviceId: deviceId),
          Uint8List.fromList(utf8.encode(plaintext)),
        );
        return WireEnvelope(
          kind: WireEnvelope.kindSignal,
          messageType: message.type.value,
          ciphertext: message.ciphertext,
        );
      });

  /// Decrypts a ratchet envelope from [peerUid].
  Future<String> decrypt(String peerUid, WireEnvelope envelope) =>
      _serialized(peerUid, () async {
        await ensureReady();
        final plaintext = await _cipher().decrypt(
          ProtocolAddress(name: peerUid, deviceId: deviceId),
          CiphertextMessage.fromRaw(
            messageType: envelope.messageType,
            ciphertext: envelope.ciphertext,
          ),
        );
        return utf8.decode(plaintext);
      });

  /// Forgets a peer's session and cached capability — used when a contact is
  /// deleted, or its identity is deliberately re-verified from scratch.
  Future<void> forgetPeer(String peerUid) async {
    await _deleteBlob(_kindSession, _ref(peerUid));
    await _deleteBlob(_kindIdentity, _ref(peerUid));
    await _deleteBlob(_kindPeer, peerUid);
    _locks.remove(peerUid);
  }

  // ─── cipher construction ───

  /// Builds the cipher for this device. The stores are stateless wrappers over
  /// shared tables, so rebuilding them per call keeps nothing stale.
  SessionCipher _cipher() {
    final name = _localName;
    if (name == null || _identity == null || _registrationId == null) {
      throw StateError('Ratchet not ready');
    }
    return SessionCipher(
      localAddress: ProtocolAddress(name: name, deviceId: deviceId),
      sessionStore: _stores,
      identityKeyStore: _stores,
      preKeyStore: _stores,
      signedPreKeyStore: _stores,
      kyberPreKeyStore: _stores,
    );
  }

  _RatchetStores? _storesInstance;

  _RatchetStores get _stores =>
      _storesInstance ??= _RatchetStores(session: this);

  // ─── raw storage ───

  static String _ref(String name) => '$name|$deviceId';

  Future<void> _storeBlob(String kind, String ref, Uint8List blob) async {
    final db = await _database();
    // Its own transaction: committed to disk before the callback returns, which
    // is the durability the ratchet stores are required to provide.
    await db.transaction((txn) async {
      await txn.insert('ratchet_store', {
        'kind': kind,
        'ref': ref,
        'blob': blob,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> _deleteBlob(String kind, String ref) async {
    final db = await _database();
    await db.transaction((txn) async {
      await txn.delete(
        'ratchet_store',
        where: 'kind = ? AND ref = ?',
        whereArgs: [kind, ref],
      );
    });
  }

  Future<Uint8List?> _loadBlob(String kind, String ref) async {
    final db = await _database();
    final maps = await db.query(
      'ratchet_store',
      columns: ['blob'],
      where: 'kind = ? AND ref = ?',
      whereArgs: [kind, ref],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    final blob = maps.first['blob'];
    if (blob is Uint8List) return blob;
    if (blob is List<int>) return Uint8List.fromList(blob);
    return null;
  }

  /// Removes every blob of one kind (all entries of a rotated key type).
  Future<void> _clearKind(String kind) async {
    final db = await _database();
    await db.transaction((txn) async {
      await txn.delete('ratchet_store', where: 'kind = ?', whereArgs: [kind]);
    });
  }

  Future<void> _deleteMeta(String key) async {
    final db = await _database();
    await db.delete('ratchet_meta', where: 'key = ?', whereArgs: [key]);
  }

  Future<void> _writeMeta(String key, String value) async {
    final db = await _database();
    await db.insert('ratchet_meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> _readMeta(String key) async {
    final db = await _database();
    final maps = await db.query(
      'ratchet_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return maps.first['value'] as String?;
  }

  // ─── helpers ───

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The libsignal store interfaces, over the shared `ratchet_store` table.
///
/// One class rather than five because they differ only in the `kind`
/// discriminator and the record type they (de)serialize; keeping them together
/// means one place where the durability and serialization rules are enforced,
/// and one place to review when the protocol adds a store.
class _RatchetStores
    implements
        SessionStore,
        IdentityKeyStore,
        PreKeyStore,
        SignedPreKeyStore,
        KyberPreKeyStore {
  _RatchetStores({required this.session});

  final RatchetSession session;

  @override
  Future<SessionRecord?> loadSession(ProtocolAddress address) async {
    final blob = await session._loadBlob(
      RatchetSession._kindSession,
      _ref(address),
    );
    if (blob == null) return null;
    return SessionRecord.deserialize(bytes: blob);
  }

  @override
  Future<void> storeSession(
    ProtocolAddress address,
    SessionRecord record,
  ) async {
    // Durable before returning: the library awaits this before releasing the
    // ciphertext, which is what stops a crash from rewinding the ratchet.
    await session._storeBlob(
      RatchetSession._kindSession,
      _ref(address),
      record.serialize(),
    );
  }

  @override
  Future<bool> containsSession(ProtocolAddress address) async =>
      await session._loadBlob(RatchetSession._kindSession, _ref(address)) !=
      null;

  @override
  Future<void> deleteSession(ProtocolAddress address) async {
    await session._deleteBlob(RatchetSession._kindSession, _ref(address));
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    final db = await session._database();
    await db.transaction((txn) async {
      await txn.delete(
        'ratchet_store',
        where: 'kind = ? AND ref LIKE ?',
        whereArgs: [RatchetSession._kindSession, '$name|%'],
      );
    });
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final db = await session._database();
    final maps = await db.query(
      'ratchet_store',
      columns: ['ref'],
      where: 'kind = ? AND ref LIKE ?',
      whereArgs: [RatchetSession._kindSession, '$name|%'],
    );
    final deviceIds = <int>[];
    for (final row in maps) {
      final ref = row['ref'] as String? ?? '';
      final id = int.tryParse(ref.split('|').last);
      if (id != null) deviceIds.add(id);
    }
    return deviceIds;
  }

  // ─── IdentityKeyStore ───

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => session._identity!;

  @override
  Future<int> getLocalRegistrationId() async => session._registrationId!;

  @override
  Future<PublicKey?> getIdentity(ProtocolAddress address) async {
    final blob = await session._loadBlob(
      RatchetSession._kindIdentity,
      _ref(address),
    );
    if (blob == null) return null;
    return PublicKey.deserialize(bytes: blob);
  }

  @override
  Future<bool> saveIdentity(
    ProtocolAddress address,
    PublicKey identityKey,
  ) async {
    final existing = await getIdentity(address);
    final incoming = identityKey.serialize();
    if (existing != null) {
      // Return "changed" but do not overwrite. Keeping the first key seen means
      // a substituted identity keeps failing the trust check instead of
      // silently replacing the one the safety number was verified against.
      return !_bytesEqual(existing.serialize(), incoming);
    }
    await session._storeBlob(
      RatchetSession._kindIdentity,
      _ref(address),
      incoming,
    );
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(
    ProtocolAddress address,
    PublicKey identityKey,
    Direction direction,
  ) async {
    // Trust on first use, reject a change. The safety number is how a change is
    // resolved deliberately; letting the ratchet accept a new key silently
    // would remove the only signal the user gets.
    final known = await getIdentity(address);
    if (known == null) return true;
    return _bytesEqual(known.serialize(), identityKey.serialize());
  }

  // ─── PreKeyStore ───
  //
  // This device publishes no one-time pre-keys (it uses a last-resort signed
  // pre-key instead), so these are only reachable when a peer's bundle names a
  // one-time pre-key of *ours* — which cannot happen with the bundles we
  // publish. They are implemented anyway: leaving them unimplemented would be a
  // latent failure the day a pool is added, and the store is one table.

  @override
  Future<PreKeyRecord?> loadPreKey(int preKeyId) async {
    final blob = await session._loadBlob(
      RatchetSession._kindPreKey,
      '$preKeyId',
    );
    if (blob == null) return null;
    return PreKeyRecord.deserialize(bytes: blob);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    await session._storeBlob(
      RatchetSession._kindPreKey,
      '$preKeyId',
      record.serialize(),
    );
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async =>
      await session._loadBlob(RatchetSession._kindPreKey, '$preKeyId') != null;

  @override
  Future<void> removePreKey(int preKeyId) async {
    // A one-time pre-key must not survive its use: the library awaits this
    // before releasing the plaintext, and a lost delete would let the same
    // initial message re-establish a session whose keys are already spent.
    await session._deleteBlob(RatchetSession._kindPreKey, '$preKeyId');
  }

  @override
  Future<List<int>> getAllPreKeyIds() async =>
      _idsOfKind(RatchetSession._kindPreKey);

  // ─── SignedPreKeyStore ───

  @override
  Future<SignedPreKeyRecord?> loadSignedPreKey(int signedPreKeyId) async {
    final blob = await session._loadBlob(
      RatchetSession._kindSignedPreKey,
      '$signedPreKeyId',
    );
    if (blob == null) return null;
    return SignedPreKeyRecord.deserialize(bytes: blob);
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    await session._storeBlob(
      RatchetSession._kindSignedPreKey,
      '$signedPreKeyId',
      record.serialize(),
    );
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async =>
      await session._loadBlob(
        RatchetSession._kindSignedPreKey,
        '$signedPreKeyId',
      ) !=
      null;

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    await session._deleteBlob(
      RatchetSession._kindSignedPreKey,
      '$signedPreKeyId',
    );
  }

  @override
  Future<List<int>> getAllSignedPreKeyIds() async =>
      _idsOfKind(RatchetSession._kindSignedPreKey);

  // ─── KyberPreKeyStore ───

  @override
  Future<KyberPreKeyRecord?> loadKyberPreKey(int kyberPreKeyId) async {
    final blob = await session._loadBlob(
      RatchetSession._kindKyberPreKey,
      '$kyberPreKeyId',
    );
    if (blob == null) return null;
    return KyberPreKeyRecord.deserialize(bytes: blob);
  }

  @override
  Future<void> storeKyberPreKey(
    int kyberPreKeyId,
    KyberPreKeyRecord record,
  ) async {
    await session._storeBlob(
      RatchetSession._kindKyberPreKey,
      '$kyberPreKeyId',
      record.serialize(),
    );
  }

  @override
  Future<bool> containsKyberPreKey(int kyberPreKeyId) async =>
      await session._loadBlob(
        RatchetSession._kindKyberPreKey,
        '$kyberPreKeyId',
      ) !=
      null;

  @override
  Future<void> removeKyberPreKey(int kyberPreKeyId) async {
    await session._deleteBlob(
      RatchetSession._kindKyberPreKey,
      '$kyberPreKeyId',
    );
  }

  @override
  Future<List<int>> getAllKyberPreKeyIds() async =>
      _idsOfKind(RatchetSession._kindKyberPreKey);

  @override
  Future<void> markKyberPreKeyUsed(
    int kyberPreKeyId,
    int signedPreKeyId,
    PublicKey baseKey,
  ) async {
    // This key is last-resort, so it stays served and the triple is recorded
    // instead. Seeing the same triple twice means one pre-key message was
    // processed twice — recorded for the app to notice, never thrown, because
    // throwing here panics the Rust worker rather than failing a decryption.
    try {
      final key =
          '$kyberPreKeyId:$signedPreKeyId:${base64Encode(baseKey.serialize())}';
      final seen = await session._loadBlob(RatchetSession._kindKyberUsed, key);
      if (seen != null) {
        CrashReporter.recordError(
          error: 'kyber pre-key message replayed (id $kyberPreKeyId)',
          source: 'ratchet-replay',
        );
        return;
      }
      await session._storeBlob(
        RatchetSession._kindKyberUsed,
        key,
        Uint8List(0),
      );
    } catch (_) {}
  }

  /// Pre-key ids of one kind, as integers.
  Future<List<int>> _idsOfKind(String kind) async {
    final db = await session._database();
    final maps = await db.query(
      'ratchet_store',
      columns: ['ref'],
      where: 'kind = ?',
      whereArgs: [kind],
    );
    final ids = <int>[];
    for (final row in maps) {
      final id = int.tryParse(row['ref'] as String? ?? '');
      if (id != null) ids.add(id);
    }
    return ids;
  }

  static String _ref(ProtocolAddress address) =>
      '${address.name()}|${address.deviceId()}';

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Random in `[0, maxExclusive)` from the system CSPRNG.
final Random _secureRandom = Random.secure();
int _randomInt(int maxExclusive) => _secureRandom.nextInt(maxExclusive);
