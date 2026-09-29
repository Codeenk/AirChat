import 'package:flutter_test/flutter_test.dart';
import 'package:air_chat/models/group.dart';

void main() {
  group('acceptsControlVersion (key rotation replay guard)', () {
    test('accepts a newer generation', () {
      expect(
        acceptsControlVersion(localVersion: 1, incomingVersion: 2),
        isTrue,
      );
    });

    test('rejects an equal generation (replay of what we already applied)', () {
      expect(
        acceptsControlVersion(localVersion: 3, incomingVersion: 3),
        isFalse,
      );
    });

    test('rejects an older generation (replayed superseded key)', () {
      expect(
        acceptsControlVersion(localVersion: 5, incomingVersion: 2),
        isFalse,
      );
    });

    test('accepts the first generation for a group we do not have yet', () {
      expect(
        acceptsControlVersion(localVersion: 0, incomingVersion: 1),
        isTrue,
      );
    });

    test('accepts an unversioned control so legacy groups keep working', () {
      expect(
        acceptsControlVersion(localVersion: 7, incomingVersion: null),
        isTrue,
      );
    });
  });

  group('Group keyVersion serialization', () {
    Group build({int keyVersion = 0}) => Group(
      id: 'grp_1',
      name: 'Team',
      memberUids: const ['a', 'b'],
      createdAt: 1,
      groupKey: 'AAAA',
      keyVersion: keyVersion,
    );

    test('round-trips keyVersion through toMap/fromMap', () {
      expect(build(keyVersion: 4).toMap()['key_version'], 4);
      expect(Group.fromMap(build(keyVersion: 4).toMap()).keyVersion, 4);
    });

    test('defaults keyVersion to 0 for a pre-v9 row', () {
      final map = build().toMap()..remove('key_version');
      expect(Group.fromMap(map).keyVersion, 0);
    });

    test('copyWith preserves keyVersion when not overridden', () {
      expect(build(keyVersion: 2).copyWith(name: 'x').keyVersion, 2);
      expect(build(keyVersion: 2).copyWith(keyVersion: 3).keyVersion, 3);
    });
  });
}
