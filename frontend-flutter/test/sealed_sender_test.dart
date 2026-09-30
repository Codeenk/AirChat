import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:air_chat/core/crypto/delivery_tag.dart';
import 'package:air_chat/core/crypto/ratchet_session.dart';
import 'package:air_chat/core/crypto/sealed_sender.dart';
import 'package:air_chat/core/crypto/wire_envelope.dart';
import 'package:air_chat/core/network/message_status.dart';
import 'package:air_chat/core/network/websocket_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// What a transport was asked to do, recorded instead of sent.
///
/// The point of the `SealedTransport` seam: every assertion here is about the
/// decision (does this ride sealed? which tag is it addressed to? which return
/// path is quoted?), not about a socket.
class _RecordingTransport implements SealedTransport {
  final List<Map<String, dynamic>> registered = [];
  final List<Map<String, dynamic>> sent = [];
  final List<Map<String, dynamic>> acks = [];
  final List<Map<String, dynamic>> receipts = [];

  @override
  void sealRegister({required String tag, String? fcmToken}) {
    registered.add({'tag': tag, 'fcm': ?fcmToken});
  }

  @override
  void sendSealed({
    required String toTag,
    required String replyTag,
    required String packetId,
    required String body,
  }) {
    sent.add({
      'to': toTag,
      'reply': replyTag,
      'packetId': packetId,
      'body': body,
    });
  }

  @override
  void sealAck({
    required String tag,
    required String packetId,
    String? replyTag,
  }) {
    acks.add({'tag': tag, 'packetId': packetId, 'reply': ?replyTag});
  }

  @override
  void sealReceipt({
    required String tag,
    required String packetId,
    String? replyTag,
  }) {
    receipts.add({'tag': tag, 'packetId': packetId, 'reply': ?replyTag});
  }
}

/// A timer that never fires on its own, so a batch can be inspected in the
/// window before it flushes.
class _ManualTimer implements Timer {
  bool _active = true;
  int _ticks = 0;

  void fire() {
    _ticks++;
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;

  @override
  void cancel() => _active = false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  Future<Database> openStore() => databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
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

  Future<RatchetSession> device(
    String uid,
    SimpleKeyPair keyPair, {
    Future<String?> Function()? deliveryTag,
  }) async {
    final db = await openStore();
    final session = RatchetSession(
      database: () async => db,
      identityKeyPair: () async => keyPair,
      uid: () async => uid,
      deliveryTag: deliveryTag,
    );
    await session.ensureReady();
    return session;
  }

  group('DeliveryTag', () {
    test('mints 256 bits of base64url that the relay would accept', () {
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        final tag = DeliveryTag.generate();
        expect(tag.length, DeliveryTag.encodedLength);
        expect(tag, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        // Exactly 32 bytes once the stripped padding is put back.
        expect(base64Url.decode('$tag=').length, DeliveryTag.byteLength);
        expect(DeliveryTag.isValid(tag), isTrue);
        expect(seen.add(tag), isTrue, reason: 'tags must not repeat');
      }
    });

    test('rejects anything that is not that shape', () {
      expect(DeliveryTag.isValid(null), isFalse);
      expect(DeliveryTag.isValid(''), isFalse);
      expect(DeliveryTag.isValid('short'), isFalse);
      // 43 chars of the wrong alphabet.
      expect(DeliveryTag.isValid('${List.filled(42, 'a').join()}+'), isFalse);
      // 43 chars but not a decodable 32-byte body.
      expect(DeliveryTag.isValid('=' * 43), isFalse);
    });

    test('rotates a day after it was minted, not before', () {
      final minted = DateTime(2026, 9, 30, 12);
      expect(DeliveryTag.rotationDue(minted, minted), isFalse);
      expect(
        DeliveryTag.rotationDue(
          minted,
          minted.add(const Duration(hours: 23, minutes: 59)),
        ),
        isFalse,
      );
      expect(
        DeliveryTag.rotationDue(minted, minted.add(const Duration(hours: 24))),
        isTrue,
      );
      // An unknown age is a reason to mint rather than to keep reusing.
      expect(DeliveryTag.rotationDue(null, minted), isTrue);
    });
  });

  group('DeliveryTagRegistry', () {
    late DateTime now;

    DeliveryTagRegistry registry() => DeliveryTagRegistry(
      storage: InMemoryDeliveryTagStorage(),
      clock: () => now,
    );

    setUp(() => now = DateTime(2026, 9, 30, 12));

    test('mints once and reuses the tag inside the rotation window', () async {
      final r = registry();
      final first = await r.ensureTag();
      expect(first, isNotNull);
      now = now.add(const Duration(hours: 23));
      expect(await r.ensureTag(), first);
      expect(await r.currentTag(), first);
    });

    test('rotates after the window and keeps the old tag for grace', () async {
      final r = registry();
      final first = (await r.ensureTag())!;
      now = now.add(const Duration(days: 1, minutes: 1));
      final second = (await r.ensureTag())!;

      expect(second, isNot(first));
      // Newest first, and the superseded tag is still claimable: a peer that
      // has not heard from us yet is still addressing the old one.
      expect(await r.activeTags(), [second, first]);
      expect(await r.currentTag(), second);
    });

    test('accumulates tags instead of replacing them', () async {
      final r = registry();
      final first = (await r.ensureTag())!;
      now = now.add(const Duration(days: 1, minutes: 1));
      final second = (await r.ensureTag())!;
      now = now.add(const Duration(days: 1, minutes: 1));
      final third = (await r.ensureTag())!;

      // Rotation adds an address; it does not take one away. A peer that has
      // not heard from us since before the last rotation is still addressing a
      // tag in this list, and mail sent to it must still arrive.
      expect(await r.activeTags(), [third, second, first]);
    });

    test('forgets a tag once it is past the grace window', () async {
      final r = registry();
      final first = (await r.ensureTag())!;
      now = now.add(const Duration(days: 1, minutes: 1));
      final second = (await r.ensureTag())!;

      // Long enough that both earlier tags fall outside the window: the point of
      // the window is that a retired tag stops being an address we accept,
      // otherwise rotation would buy nothing.
      now = now.add(DeliveryTag.keepPrevious + const Duration(days: 2));
      final third = (await r.ensureTag())!;

      expect(await r.activeTags(), [third]);
      expect(await r.activeTags(), isNot(contains(first)));
      expect(await r.activeTags(), isNot(contains(second)));
    });

    test('re-mints rather than reusing a corrupt record', () async {
      final storage = InMemoryDeliveryTagStorage([
        TagRecord(tag: 'not-a-tag', mintedAt: now),
      ]);
      final r = DeliveryTagRegistry(storage: storage, clock: () => now);
      final minted = await r.ensureTag();
      expect(DeliveryTag.isValid(minted), isTrue);
    });

    test(
      'registers every active tag, newest first, with the wake token',
      () async {
        final r = registry();
        final first = (await r.ensureTag())!;
        now = now.add(const Duration(days: 1, minutes: 1));
        final second = (await r.ensureTag())!;

        final transport = _RecordingTransport();
        expect(await r.registerOn(transport, fcmToken: 'tok'), 2);
        expect(transport.registered, [
          {'tag': second, 'fcm': 'tok'},
          {'tag': first, 'fcm': 'tok'},
        ]);
      },
    );

    test('survives storage that cannot be written', () async {
      final storage = _BrokenStorage();
      final r = DeliveryTagRegistry(storage: storage, clock: () => now);

      // A keystore that fails must never crash or block sending. The tag still
      // works for this run (it is cached in memory), so the device stays
      // reachable — losing metadata privacy is better than losing messages.
      final transport = _RecordingTransport();
      expect(await r.registerOn(transport), 1);
      expect(
        DeliveryTag.isValid(transport.registered.single['tag'] as String),
        isTrue,
      );

      // What is lost is durability: a fresh run over the same broken storage
      // has nothing to reuse.
      final restart = DeliveryTagRegistry(storage: storage, clock: () => now);
      expect(await restart.currentTag(), isNull);
    });
  });

  group('SealedBatcher', () {
    test(
      'holds a burst and releases it together, inside the jitter window',
      () {
        final emitted = <Map<String, dynamic>>[];
        Duration? armedFor;
        var timersArmed = 0;
        void Function()? fire;
        _ManualTimer? timer;

        final batcher = SealedBatcher(
          emit: emitted.add,
          random: Random(7),
          timerFactory: (duration, callback) {
            timersArmed++;
            armedFor = duration;
            fire = callback;
            timer = _ManualTimer();
            return timer!;
          },
        );

        batcher.submit({'pid': '1'});
        expect(
          emitted,
          isEmpty,
          reason: 'submission time must not be send time',
        );
        expect(
          armedFor!.inMilliseconds,
          inInclusiveRange(SealedBatcher.minDelayMs, SealedBatcher.maxDelayMs),
        );

        batcher.submit({'pid': '2'});
        batcher.submit({'pid': '3'});
        expect(batcher.pending, 3);
        // One timer for the batch: a later arrival joins the flush in flight
        // instead of pushing it back, which would let a chatty sender stall
        // delivery indefinitely.
        expect(timersArmed, 1);

        fire!();
        expect(emitted.map((p) => p['pid']).toList(), ['1', '2', '3']);
        expect(batcher.pending, 0);
        expect(timer!.isActive, isFalse);
      },
    );

    test('flushes on demand, which is what a reconnect needs', () {
      final emitted = <Map<String, dynamic>>[];
      final batcher = SealedBatcher(emit: emitted.add, random: Random(1));
      batcher.submit({'pid': '1'});
      batcher.flushNow();
      expect(emitted.length, 1);
      batcher.dispose();
    });

    test('dispose drops a pending batch instead of leaking it', () {
      final emitted = <Map<String, dynamic>>[];
      final batcher = SealedBatcher(
        emit: emitted.add,
        timerFactory: (d, f) => _ManualTimer(),
      );
      batcher.submit({'pid': '1'});
      batcher.dispose();
      expect(emitted, isEmpty);
      expect(batcher.pending, 0);
    });
  });

  group('sealed send', () {
    late DeliveryTagRegistry tags;
    late _RecordingTransport transport;

    setUp(() {
      tags = DeliveryTagRegistry(
        storage: InMemoryDeliveryTagStorage(),
        clock: () => DateTime(2026, 9, 30, 12),
      );
      transport = _RecordingTransport();
    });

    test('refuses a payload that cannot name its own sender', () async {
      await tags.ensureTag();
      final session = await device('uid_alice', await X25519().newKeyPair());
      await session.rememberPeerTag('uid_bob', DeliveryTag.generate());
      final sealed = SealedSender(tags: tags, ratchet: session);

      // A legacy X25519 envelope: AEAD only, no sender identity inside. Sealing
      // it would leave the recipient unable to attribute it, so it must stay on
      // the named transport.
      const legacy = '{"ct":"AAAA","n":"BBBB","epk":"CCCC"}';
      expect(
        await sealed.send(
          client: transport,
          peerUid: 'uid_bob',
          packetId: 'p1',
          body: legacy,
        ),
        isFalse,
      );
      expect(transport.sent, isEmpty);
    });

    test('refuses when we have no tag to be replied to on', () async {
      final session = await device('uid_alice', await X25519().newKeyPair());
      await session.rememberPeerTag('uid_bob', DeliveryTag.generate());
      final sealed = SealedSender(tags: tags, ratchet: session);
      final envelope = WireEnvelope(
        kind: WireEnvelope.kindSignal,
        messageType: SealedSender.typeSignal,
        ciphertext: Uint8List.fromList([1, 2, 3]),
      );

      expect(
        await sealed.send(
          client: transport,
          peerUid: 'uid_bob',
          packetId: 'p1',
          body: envelope.encode(),
        ),
        isFalse,
      );
    });

    test('refuses when the peer has never told us a tag', () async {
      await tags.ensureTag();
      final session = await device('uid_alice', await X25519().newKeyPair());
      final sealed = SealedSender(tags: tags, ratchet: session);
      final envelope = WireEnvelope(
        kind: WireEnvelope.kindSignal,
        messageType: SealedSender.typeSignal,
        ciphertext: Uint8List.fromList([1, 2, 3]),
      );

      // No tag for the peer means they are on a build that predates sealed
      // delivery, so this message goes out named and still arrives.
      expect(
        await sealed.send(
          client: transport,
          peerUid: 'uid_bob',
          packetId: 'p1',
          body: envelope.encode(),
        ),
        isFalse,
      );
    });

    test('addresses the device, not the user, when both ends can', () async {
      final ourTag = (await tags.ensureTag())!;
      final session = await device('uid_alice', await X25519().newKeyPair());
      final peerTag = DeliveryTag.generate();
      await session.rememberPeerTag('uid_bob', peerTag);
      final sealed = SealedSender(tags: tags, ratchet: session);
      final envelope = WireEnvelope(
        kind: WireEnvelope.kindSignal,
        messageType: SealedSender.typeSignal,
        ciphertext: Uint8List.fromList([1, 2, 3]),
      );

      expect(
        await sealed.send(
          client: transport,
          peerUid: 'uid_bob',
          packetId: 'p1',
          body: envelope.encode(),
        ),
        isTrue,
      );
      expect(transport.sent.single['to'], peerTag);
      expect(transport.sent.single['reply'], ourTag);
      // Neither end's uid appears anywhere on the wire.
      expect(transport.sent.single.toString(), isNot(contains('uid_')));
    });

    test('acks and receipts name a packet and a tag, never a person', () async {
      final sealed = SealedSender(
        tags: tags,
        ratchet: await device('uid_bob', await X25519().newKeyPair()),
      );
      const ourTag = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      const peerTag = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

      sealed.ack(
        client: transport,
        tag: ourTag,
        packetId: 'p1',
        replyTag: peerTag,
      );
      sealed.receipt(
        client: transport,
        tag: ourTag,
        packetId: 'p1',
        replyTag: peerTag,
      );

      // `tag` scopes the delete to our own address; `reply` is the only routing
      // information, and it is opaque. Neither says who anyone is.
      expect(transport.acks.single['tag'], ourTag);
      expect(transport.acks.single['reply'], peerTag);
      expect(transport.receipts.single['tag'], ourTag);
      expect(transport.receipts.single['reply'], peerTag);
      expect(
        transport.acks.single.keys,
        isNot(contains(anyOf('senderUid', 'recipientUid'))),
      );
    });

    test('an invalid peer tag is not remembered', () async {
      final session = await device('uid_alice', await X25519().newKeyPair());
      final sealed = SealedSender(tags: tags, ratchet: session);
      await sealed.rememberPeerTag('uid_bob', 'nonsense');
      expect(await session.peerTag('uid_bob'), isNull);
    });

    test('a peer tag round-trips through the session store', () async {
      final session = await device('uid_alice', await X25519().newKeyPair());
      final tag = DeliveryTag.generate();
      await session.rememberPeerTag('uid_bob', tag);
      expect(await session.peerTag('uid_bob'), tag);
      // and can be forgotten
      await session.rememberPeerTag('uid_bob', null);
      expect(await session.peerTag('uid_bob'), isNull);
    });
  });

  group('sealed receive', () {
    test('a first message is attributed by the identity inside it', () async {
      final aliceKey = await X25519().newKeyPair();
      final alice = await device('uid_alice', aliceKey);
      final bob = await device('uid_bob', await X25519().newKeyPair());
      final aliceIdentity = await alice.localIdentityKeyBase64();

      final aliceTags = DeliveryTagRegistry(
        storage: InMemoryDeliveryTagStorage(),
      );
      final aliceTag = (await aliceTags.ensureTag())!;
      final bobTag = DeliveryTag.generate();
      // How Alice learns both things she needs before writing: Bob's bundle
      // (for the session and his tag) and then his tag, remembered.
      await alice.ensureSession('uid_bob', (await bob.localBundlePayload())!);
      await alice.rememberPeerTag('uid_bob', bobTag);

      final aliceSender = SealedSender(tags: aliceTags, ratchet: alice);
      final transport = _RecordingTransport();
      final envelope = await alice.encrypt(
        'uid_bob',
        jsonEncode({'text': 'sealed hello', 'dt': aliceTag}),
      );
      // First message of a pair: a pre-key message, with no session on Bob's
      // side yet.
      expect(envelope.messageType, SealedSender.typePreKey);
      expect(
        await aliceSender.send(
          client: transport,
          peerUid: 'uid_bob',
          packetId: 'p1',
          body: envelope.encode(),
        ),
        isTrue,
      );

      final bobOpens = SealedSender(
        tags: DeliveryTagRegistry(storage: InMemoryDeliveryTagStorage()),
        ratchet: bob,
        knownIdentities: () async => {'uid_alice': aliceIdentity!},
      );

      final opened = await bobOpens.open(
        body: transport.sent.single['body'] as String,
        packetId: 'p1',
      );
      expect(opened, isNotNull);
      expect(opened!.senderUid, 'uid_alice');
      expect(jsonDecode(opened.plaintext)['text'], 'sealed hello');
      // The tag inside the payload is what a reply is sealed to.
      expect(jsonDecode(opened.plaintext)['dt'], aliceTag);

      // The reply travels back the same way, and needs no identity filter: both
      // ends now hold a session, so the sender is whatever session opens it.
      await bob.rememberPeerTag('uid_alice', aliceTag);
      final reply = await bob.encrypt('uid_alice', 'hi back');
      final aliceOpens = SealedSender(
        tags: DeliveryTagRegistry(storage: InMemoryDeliveryTagStorage()),
        ratchet: alice,
      );
      final openedReply = await aliceOpens.open(
        body: reply.encode(),
        packetId: 'p2',
      );
      expect(openedReply?.senderUid, 'uid_bob');
      expect(openedReply?.plaintext, 'hi back');
    });

    test(
      'an established session is found by walking our own sessions',
      () async {
        final alice = await device('uid_alice', await X25519().newKeyPair());
        final bob = await device('uid_bob', await X25519().newKeyPair());
        await alice.ensureSession('uid_bob', (await bob.localBundlePayload())!);

        final first = await alice.encrypt('uid_bob', 'one');
        expect(first.messageType, SealedSender.typePreKey);

        final bobOpens = SealedSender(
          tags: DeliveryTagRegistry(storage: InMemoryDeliveryTagStorage()),
          ratchet: bob,
          knownIdentities: () async => const {},
        );
        // A pre-key message from someone Bob holds no identity for cannot be
        // attributed at all: any label would decrypt it (see the label test
        // below), so with nothing to check the identity against, open() refuses
        // rather than guessing. The caller keeps the packet.
        expect(
          await bobOpens.open(body: first.encode(), packetId: 'p1'),
          isNull,
        );

        // Once the session exists — here by the named transport naming the
        // sender, which is how it happens in production too — attribution needs
        // neither a hint nor the relay.
        await bob.decrypt('uid_alice', first);
        expect(await bob.sessionPeers(), contains('uid_alice'));

        // Alice's ratchet is only *established* once she has heard back: until
        // then her messages stay pre-key messages, because Bob might still have
        // no session at all.
        final reply = await bob.encrypt('uid_alice', 'hi');
        await alice.decrypt('uid_bob', reply);

        final second = await alice.encrypt('uid_bob', 'two');
        expect(second.messageType, SealedSender.typeSignal);
        final opened = await bobOpens.open(
          body: second.encode(),
          packetId: 'p2',
        );
        expect(opened?.senderUid, 'uid_alice');
        expect(opened?.plaintext, 'two');
      },
    );

    test('a stranger is not attributed to a contact', () async {
      final aliceKey = await X25519().newKeyPair();
      final charlie = await device('uid_charlie', await X25519().newKeyPair());
      final bob = await device('uid_bob', await X25519().newKeyPair());

      // Bob only knows Alice's identity. Charlie writes to him and must not be
      // attributed to her: the envelope's identity key does not match, so there
      // is no candidate at all, and no decrypt is attempted.
      final aliceOnly = SealedSender(
        tags: DeliveryTagRegistry(storage: InMemoryDeliveryTagStorage()),
        ratchet: bob,
        knownIdentities: () async => {
          'uid_alice': base64Encode((await aliceKey.extractPublicKey()).bytes),
        },
      );

      await charlie.ensureSession('uid_bob', (await bob.localBundlePayload())!);
      final fromCharlie = await charlie.encrypt(
        'uid_bob',
        jsonEncode({'text': 'hi'}),
      );
      expect(
        await aliceOnly.open(body: fromCharlie.encode(), packetId: 'p1'),
        isNull,
      );
    });

    test('a body that is not a ciphertext is never attributed', () async {
      final bob = await device('uid_bob', await X25519().newKeyPair());
      final sealed = SealedSender(
        tags: DeliveryTagRegistry(storage: InMemoryDeliveryTagStorage()),
        ratchet: bob,
        knownIdentities: () async => {},
      );
      expect(await sealed.open(body: 'not json', packetId: 'p1'), isNull);
      expect(
        await sealed.open(
          body: '{"ct":"AA","n":"BB","epk":"CC"}',
          packetId: 'p2',
        ),
        isNull,
      );
    });

    test('a label is not an identity, which is why the key is checked', () async {
      final alice = await device('uid_alice', await X25519().newKeyPair());
      final bob = await device('uid_bob', await X25519().newKeyPair());
      await alice.ensureSession('uid_bob', (await bob.localBundlePayload())!);
      final real = await alice.encrypt('uid_bob', 'for bob only');

      // The sharp edge of trial decryption, pinned down: libsignal labels a
      // session with whatever address we hand it, and the cryptography does not
      // care what we call the peer. A first message therefore opens under *any*
      // label — so an unfiltered trial would happily attribute Alice's message
      // to Carol. What prevents that is not the decryption, it is
      // [SealedSender]'s identity-key filter: only a contact whose stored key
      // matches the one inside the envelope is ever tried.
      expect(await bob.decrypt('uid_carol', real), 'for bob only');

      // And the message is not consumed by a wrong attempt: the real recipient
      // still opens it afterwards.
      expect(await bob.decrypt('uid_alice', real), 'for bob only');
    });
  });

  group('bundle carries the tag', () {
    test('a tagged device publishes a bundle naming its tag', () async {
      final tags = DeliveryTagRegistry(storage: InMemoryDeliveryTagStorage());
      final tag = (await tags.ensureTag())!;
      final session = await device(
        'uid_alice',
        await X25519().newKeyPair(),
        deliveryTag: tags.currentTag,
      );

      final bundle = RatchetBundle.tryDecode(
        (await session.localBundlePayload())!,
      );
      expect(bundle!.deliveryTag, tag);
    });

    test('an untagged device publishes a bundle without one', () async {
      final session = await device(
        'uid_alice',
        await X25519().newKeyPair(),
        deliveryTag: () async => null,
      );
      final bundle = RatchetBundle.tryDecode(
        (await session.localBundlePayload())!,
      );
      expect(bundle!.deliveryTag, isNull);
    });

    test('a registry failure costs the tag, not the bundle', () async {
      final session = await device(
        'uid_alice',
        await X25519().newKeyPair(),
        deliveryTag: () async => throw StateError('keystore unavailable'),
      );
      // Without this the device would publish nothing at all, and every
      // conversation would lose forward secrecy because of a keystore hiccup.
      final payload = await session.localBundlePayload();
      expect(payload, isNotNull);
      expect(RatchetBundle.tryDecode(payload!)!.deliveryTag, isNull);
    });
  });

  group('sealed status vocabulary', () {
    test('a routing failure is terminal, not a reason to keep waiting', () {
      expect(mapSealedFailure('unknown_recipient'), 'failed');
      expect(mapSealedFailure('not_registered'), 'failed');
      expect(mapSealedFailure('invalid_request'), 'failed');
      expect(mapSealedFailure('unavailable'), 'failed');
      // The success vocabulary belongs to the other mapper.
      expect(mapSealedFailure('relayed'), isNull);
      expect(mapRelayStatus('relayed'), 'delivered');
      expect(mapRelayStatus('queued_ephemeral'), 'sent');
    });
  });
}

/// Storage that fails every call, standing in for an unavailable keystore.
class _BrokenStorage implements DeliveryTagStorage {
  @override
  Future<List<TagRecord>> load() async => throw StateError('no keystore');

  @override
  Future<void> save(List<TagRecord> records) async =>
      throw StateError('no keystore');
}
