import 'package:flutter_test/flutter_test.dart';
import 'package:air_chat/core/crypto/qr_payload.dart';

void main() {
  group('QrContactPayload', () {
    test('encodes to the v1 AirChat JSON format', () {
      final payload = QrContactPayload(
        uid: 'usr_abc123',
        username: 'sarvesh',
        identityPublicKey: 'BASE64KEY==',
      );

      final map = payload.toJson();
      expect(map['airchat'], 'v1');
      expect(map['uid'], 'usr_abc123');
      expect(map['username'], 'sarvesh');
      expect(map['pk'], 'BASE64KEY==');
    });

    test('round-trips through encode/parse', () {
      final original = QrContactPayload(
        uid: 'usr_xyz789',
        username: 'alice',
        identityPublicKey: 'PUBKEY',
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

    test('parse defaults missing username to Peer', () {
      final parsed = QrContactPayload.parse('{"uid":"u","pk":"k"}');
      expect(parsed!.username, 'Peer');
    });
  });
}
