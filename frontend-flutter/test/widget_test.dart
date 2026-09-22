import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:air_chat/core/crypto/qr_payload.dart';

// Real 32-byte base64 key (what production QR codes carry).
const _realKey = 'UTsI1PfzU3UxsBevH4K63V8oPYrVApzuq3QXa2t0PUk=';

void main() {
  group('QrContactPayload', () {
    test('encodes to the v1 AirChat JSON format', () {
      final payload = QrContactPayload(
        uid: 'usr_abc123',
        username: 'sarvesh',
        identityPublicKey: _realKey,
      );

      final map = payload.toJson();
      expect(map['airchat'], 'v1');
      expect(map['uid'], 'usr_abc123');
      expect(map['username'], 'sarvesh');
      expect(map['pk'], _realKey);
    });

    test('round-trips through encode/parse', () {
      final original = QrContactPayload(
        uid: 'usr_xyz789',
        username: 'alice',
        identityPublicKey: _realKey,
      );

      final parsed = QrContactPayload.parse(original.encode());
      expect(parsed, isNotNull);
      expect(parsed!.uid, original.uid);
      expect(parsed.username, original.username);
      expect(parsed.identityPublicKey, original.identityPublicKey);
    });

    test('parse returns null for invalid JSON', () {
      expect(QrContactPayload.parse('not json'), isNull);
    });

    test('parse rejects payloads without uid or key', () {
      expect(QrContactPayload.parse('{"airchat":"v1"}'), isNull);
      expect(QrContactPayload.parse('{"airchat":"v1","uid":"u"}'), isNull);
    });

    test('parse rejects non-32-byte keys', () {
      expect(QrContactPayload.parse('{"uid":"u","pk":"PUBKEY"}'), isNull);
      expect(QrContactPayload.parse('{"uid":"u","pk":"BASE64KEY=="}'), isNull);
    });

    test('parse defaults missing username to Peer', () {
      final parsed = QrContactPayload.parse('{"uid":"u","pk":"$_realKey"}');
      expect(parsed!.username, 'Peer');
    });

    test('parse tolerates wrapped/quoted clipboard text', () {
      final raw =
          'AirChat contact: {"airchat":"v1","uid":"u1","username":"bob","pk":"$_realKey"} shared via chat';
      final parsed = QrContactPayload.parse(raw);
      expect(parsed, isNotNull);
      expect(parsed!.uid, 'u1');
      final quoted = '"${jsonEncode({'uid': 'u2', 'pk': _realKey})}"';
      expect(QrContactPayload.parse(quoted)?.uid, 'u2');
    });
  });
}
