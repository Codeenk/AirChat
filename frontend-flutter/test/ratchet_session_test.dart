import 'dart:convert';
import 'dart:typed_data';

import 'package:air_chat/core/crypto/ratchet_session.dart';
import 'package:air_chat/core/crypto/wire_envelope.dart';
import 'package:air_chat/models/chat_thread.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// These tests run the real libsignal implementation, not a stand-in. Each
/// "device" below owns its own X25519 identity, its own SQLite store and its own
/// [RatchetSession], and every bundle, pre-key message and ratchet step is
/// genuine Signal Protocol material.
///
/// That is the point: the ratchet is the audited part, and a test against a fake
/// would only prove the fake agrees with itself. What is worth asserting here is
/// the *wiring* — that the app's identity key is the one the ratchet
/// authenticates, that two devices can actually exchange messages through this
/// service, and that the envelope cannot be confused with the legacy one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // sqflite_common_ffi gives the stores a real SQLite database (the tests are
  // not on a device, so the SQLCipher plugin is unavailable). The store code
  // under test is the same; only the file-level encryption differs.
  sqfliteFfiInit();

  late RatchetSession alice;
  late RatchetSession bob;
  late SimpleKeyPair aliceKeyPair;

  Future<Database> openStore() => databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      // Each "device" must get its own in-memory database. sqflite otherwise
      // hands out one shared connection for ':memory:', which would let two
      // devices read each other's stores and quietly invalidate the test.
      singleInstance: false,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE ratchet_store (
            kind TEXT NOT NULL,
            ref TEXT NOT NULL,
            blob BLOB,
            PRIMARY KEY (kind, ref)
          )
        ''');
        await db.execute('''
          CREATE TABLE ratchet_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    ),
  );

  Future<RatchetSession> device(String uid, SimpleKeyPair keyPair) async {
    final db = await openStore();
    final session = RatchetSession(
      database: () async => db,
      identityKeyPair: () async => keyPair,
      uid: () async => uid,
    );
    await session.ensureReady();
    return session;
  }

  setUp(() async {
    aliceKeyPair = await X25519().newKeyPair();
    alice = await device('uid_alice', aliceKeyPair);
    bob = await device('uid_bob', await X25519().newKeyPair());
  });

  group('RatchetSession', () {
    test(
      'is available, and authenticates the app\'s own X25519 identity',
      () async {
        expect(alice.available, isTrue);

        final publicBytes = (await aliceKeyPair.extractPublicKey()).bytes;
        expect(await alice.localIdentityKeyBase64(), base64Encode(publicBytes));
      },
    );

    test(
      'publishes a bundle every field of which is public key material',
      () async {
        final payload = await alice.localBundlePayload();
        expect(payload, isNotNull);

        final bundle = RatchetBundle.tryDecode(payload!);
        expect(bundle, isNotNull);
        // 1 type byte + 32 key bytes: the same identity the directory holds.
        expect(bundle!.identityKey.length, 33);
        expect(bundle.deviceId, RatchetSession.deviceId);
        expect(bundle.signedPreKeySignature, isNotEmpty);
        expect(bundle.kyberPreKeySignature, isNotEmpty);

        // It round-trips, which is what a peer on the other side has to do.
        expect(RatchetBundle.tryDecode(bundle.encode())!.encode(), payload);
      },
    );

    test('establishes a session and exchanges messages both ways', () async {
      final aliceBundle = await alice.localBundlePayload();
      final bobBundle = await bob.localBundlePayload();
      expect(aliceBundle, isNotNull);
      expect(bobBundle, isNotNull);

      expect(await alice.ensureSession('uid_bob', bobBundle!), isTrue);
      expect(await bob.ensureSession('uid_alice', aliceBundle!), isTrue);

      final first = await alice.encrypt('uid_bob', 'hello bob');
      // The first message must be a pre-key message: that is what carries the
      // X3DH material Bob needs, and what makes it possible to write to someone
      // who has never been online at the same time.
      expect(first.kind, WireEnvelope.kindSignal);
      expect(first.messageType, 3);
      expect(await bob.decrypt('uid_alice', first), 'hello bob');

      // Bob now has a session and can reply on the ratchet, which is the whole
      // point of it being a *double* ratchet.
      final reply = await bob.encrypt('uid_alice', 'hi alice');
      expect(await alice.decrypt('uid_bob', reply), 'hi alice');
    });

    test('keeps working across several messages in each direction', () async {
      await alice.ensureSession('uid_bob', (await bob.localBundlePayload())!);
      await bob.ensureSession('uid_alice', (await alice.localBundlePayload())!);

      for (var i = 0; i < 5; i++) {
        final toBob = await alice.encrypt('uid_bob', 'a$i');
        expect(await bob.decrypt('uid_alice', toBob), 'a$i');
        final toAlice = await bob.encrypt('uid_alice', 'b$i');
        expect(await alice.decrypt('uid_bob', toAlice), 'b$i');
      }
    });

    test(
      'delivers out of order, which is what a ratchet has to survive',
      () async {
        await alice.ensureSession('uid_bob', (await bob.localBundlePayload())!);

        final first = await alice.encrypt('uid_bob', 'first');
        final second = await alice.encrypt('uid_bob', 'second');
        final third = await alice.encrypt('uid_bob', 'third');

        // The relay makes no ordering promise, so a later message can arrive
        // first. The skipped-key chain is what makes that recoverable.
        expect(await bob.decrypt('uid_alice', third), 'third');
        expect(await bob.decrypt('uid_alice', first), 'first');
        expect(await bob.decrypt('uid_alice', second), 'second');
      },
    );

    test('re-feeding a bundle does not rewind a live session', () async {
      final bobBundle = (await bob.localBundlePayload())!;
      await alice.ensureSession('uid_bob', bobBundle);

      final before = await alice.encrypt('uid_bob', 'one');
      expect(await bob.decrypt('uid_alice', before), 'one');

      // A republish is routine (every launch). Processing it again would
      // reset the ratchet to its initial state and reuse message keys.
      expect(await alice.ensureSession('uid_bob', bobBundle), isTrue);
      final after = await alice.encrypt('uid_bob', 'two');
      expect(await bob.decrypt('uid_alice', after), 'two');
    });

    test('refuses to encrypt without a session', () async {
      await expectLater(
        alice.encrypt('uid_carol', 'nobody there'),
        throwsA(anything),
      );
    });

    test(
      'rejects tampered ciphertext rather than returning wrong plaintext',
      () async {
        await alice.ensureSession('uid_bob', (await bob.localBundlePayload())!);
        final message = await alice.encrypt('uid_bob', 'important');

        // Flip one bit of the authenticated ciphertext. The AEAD must fail
        // closed: a modified message can never surface as content.
        final bytes = Uint8List.fromList(message.ciphertext);
        bytes[bytes.length - 1] ^= 0xFF;
        final tampered = WireEnvelope(
          kind: message.kind,
          messageType: message.messageType,
          ciphertext: bytes,
        );

        await expectLater(
          bob.decrypt('uid_alice', tampered),
          throwsA(anything),
        );
      },
    );

    test(
      'remembers peer capability, distinguishing "none" from "unknown"',
      () async {
        expect(await alice.cachedPeerIdentity('uid_bob'), isNull);

        await alice.rememberPeer('uid_bob', null);
        expect(await alice.cachedPeerIdentity('uid_bob'), '');

        await alice.rememberPeer('uid_bob', 'someIdentityKey');
        expect(await alice.cachedPeerIdentity('uid_bob'), 'someIdentityKey');
      },
    );

    test('forgetPeer drops the session so nothing resumes from it', () async {
      await alice.ensureSession('uid_bob', (await bob.localBundlePayload())!);
      expect(await alice.hasSession('uid_bob'), isTrue);

      await alice.forgetPeer('uid_bob');
      expect(await alice.hasSession('uid_bob'), isFalse);
      expect(await alice.cachedPeerIdentity('uid_bob'), isNull);
    });
  });

  group('WireEnvelope', () {
    test('a v2 envelope is recognised and carries its family and type', () {
      final envelope = WireEnvelope(
        kind: WireEnvelope.kindSignal,
        messageType: 3,
        ciphertext: Uint8List.fromList([1, 2, 3, 4]),
      );
      final decoded = WireEnvelope.tryDecode(envelope.encode());
      expect(decoded, isNotNull);
      expect(decoded!.kind, WireEnvelope.kindSignal);
      expect(decoded.messageType, 3);
      expect(decoded.ciphertext, [1, 2, 3, 4]);
    });

    test('a legacy envelope is not mistaken for a v2 one', () {
      // Exactly what the current released clients put on the wire.
      final legacy = jsonEncode({'ct': 'AAAA', 'n': 'BBBB', 'epk': 'CCCC'});
      expect(WireEnvelope.tryDecode(legacy), isNull);
    });

    test('malformed or unknown input decodes to null rather than throwing', () {
      expect(WireEnvelope.tryDecode('not json'), isNull);
      expect(WireEnvelope.tryDecode(jsonEncode({'v': 3, 'k': 'sig'})), isNull);
      expect(WireEnvelope.tryDecode(jsonEncode({'v': 2, 'k': 'nope'})), isNull);
      expect(WireEnvelope.tryDecode(jsonEncode({'v': 2, 'k': 'sig'})), isNull);
    });

    test('an MLS envelope is self-describing and distinct from Signal', () {
      final mls = WireEnvelope(
        kind: WireEnvelope.kindMls,
        messageType: 0,
        ciphertext: Uint8List.fromList([9, 9]),
      );
      expect(WireEnvelope.tryDecode(mls.encode())!.kind, WireEnvelope.kindMls);
    });
  });

  group('ChatCrypto version tag', () {
    test('existing chats default to the legacy path', () {
      final existing = ChatThread(
        id: 'a_b',
        contactUid: 'b',
        lastMessage: '',
        lastMessageTime: 0,
      );
      expect(existing.cryptoVersion, ChatCrypto.legacyX25519);
      expect(existing.usesRatchet, isFalse);
    });

    test('only version 2 and above is the ratchet', () {
      expect(ChatCrypto.usesRatchet(ChatCrypto.legacyX25519), isFalse);
      expect(ChatCrypto.usesRatchet(ChatCrypto.doubleRatchet), isTrue);
    });

    test('round-trips through the database map', () {
      final thread = ChatThread(
        id: 'a_b',
        contactUid: 'b',
        lastMessage: 'hi',
        lastMessageTime: 1,
        cryptoVersion: ChatCrypto.doubleRatchet,
      );
      final restored = ChatThread.fromMap(thread.toMap());
      expect(restored.cryptoVersion, ChatCrypto.doubleRatchet);
      expect(restored.usesRatchet, isTrue);
    });

    test('a map without the column reads as legacy, not as ratchet', () {
      final restored = ChatThread.fromMap({
        'id': 'a_b',
        'contact_uid': 'b',
        'last_message': '',
        'last_message_time': 0,
        'unread_count': 0,
      });
      expect(restored.cryptoVersion, ChatCrypto.legacyX25519);
      expect(restored.usesRatchet, isFalse);
    });
  });
}
