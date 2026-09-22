import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:air_chat/core/crypto/signing_engine.dart';
import 'package:air_chat/core/crypto/sodium_engine.dart';

void main() {
  group('SodiumEngine (X25519 + ChaCha20-Poly1305)', () {
    test('round-trips a 1:1 message between two identities', () async {
      final engine = SodiumEngine();
      final alice = await engine.generateIdentityKeyPair();
      final bob = await engine.generateIdentityKeyPair();
      final bobPub = await engine.exportPublicKey(bob);

      final payload = await engine.encryptMessage(
        plainText: 'hello bob',
        recipientPublicKey: await engine.importPublicKey(bobPub),
        senderKeyPair: alice,
      );
      final plain = await engine.decryptMessage(
        payload: payload,
        recipientKeyPair: bob,
      );
      expect(plain, 'hello bob');
    });

    test('uses a fresh nonce per message (no reuse)', () async {
      final engine = SodiumEngine();
      final alice = await engine.generateIdentityKeyPair();
      final bobPub = await engine.exportPublicKey(
        await engine.generateIdentityKeyPair(),
      );
      final a = await engine.encryptMessage(
        plainText: 'x',
        recipientPublicKey: await engine.importPublicKey(bobPub),
        senderKeyPair: alice,
      );
      final b = await engine.encryptMessage(
        plainText: 'x',
        recipientPublicKey: await engine.importPublicKey(bobPub),
        senderKeyPair: alice,
      );
      expect(a.nonce, isNot(b.nonce));
      expect(a.cipherText, isNot(b.cipherText));
    });

    test('group symmetric encryption round-trips with a shared key', () async {
      final engine = SodiumEngine();
      final key = base64Encode(List<int>.generate(32, (i) => i));
      final enc = await engine.encryptGroupMessage(
        plainText: 'group hello',
        groupKeyBase64: key,
      );
      final dec = await engine.decryptGroupMessage(
        payload: enc,
        groupKeyBase64: key,
      );
      expect(dec, 'group hello');
    });

    test('tampered ciphertext fails to decrypt', () async {
      final engine = SodiumEngine();
      final alice = await engine.generateIdentityKeyPair();
      final bob = await engine.generateIdentityKeyPair();
      final payload = await engine.encryptMessage(
        plainText: 'secret',
        recipientPublicKey: await engine.importPublicKey(
          await engine.exportPublicKey(bob),
        ),
        senderKeyPair: alice,
      );
      final tampered = CryptoPayload(
        cipherText: base64Encode(
          List<int>.from(base64Decode(payload.cipherText))..[0] ^= 0xFF,
        ),
        nonce: payload.nonce,
        senderEphemeralPublicKey: payload.senderEphemeralPublicKey,
      );
      expect(
        () => engine.decryptMessage(payload: tampered, recipientKeyPair: bob),
        throwsA(anything),
      );
    });
  });

  group('SigningEngine (Ed25519)', () {
    test('signs and verifies hex signatures', () async {
      final engine = SigningEngine();
      final kp = await engine.generateSigningKeyPair();
      final pub = await engine.exportSigningPublicKeyHex(kp);
      final sig = await engine.signHex('register|usr_1|PUBKEY', kp);
      expect(
        await engine.verifyHex(
          message: 'register|usr_1|PUBKEY',
          signatureHex: sig,
          publicKeyHex: pub,
        ),
        isTrue,
      );
    });

    test('rejects a signature over a different message', () async {
      final engine = SigningEngine();
      final kp = await engine.generateSigningKeyPair();
      final pub = await engine.exportSigningPublicKeyHex(kp);
      final sig = await engine.signHex('register|usr_1|PUBKEY', kp);
      expect(
        await engine.verifyHex(
          message: 'register|usr_2|PUBKEY',
          signatureHex: sig,
          publicKeyHex: pub,
        ),
        isFalse,
      );
    });

    test('rejects a signature from a different key', () async {
      final engine = SigningEngine();
      final kp = await engine.generateSigningKeyPair();
      final other = await engine.generateSigningKeyPair();
      final otherPub = await engine.exportSigningPublicKeyHex(other);
      final sig = await engine.signHex('packet|text|chat', kp);
      expect(
        await engine.verifyHex(
          message: 'packet|text|chat',
          signatureHex: sig,
          publicKeyHex: otherPub,
        ),
        isFalse,
      );
    });
  });
}
