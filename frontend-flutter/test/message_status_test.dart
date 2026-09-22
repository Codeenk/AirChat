import 'package:flutter_test/flutter_test.dart';
import 'package:air_chat/core/network/message_status.dart';
import 'package:air_chat/core/theme/time_format.dart';
import 'package:air_chat/state/chat_provider.dart';

void main() {
  group('mapRelayStatus', () {
    test('relayed means delivered, never read', () {
      expect(mapRelayStatus('relayed'), 'delivered');
    });

    test('queued_ephemeral means sent, never read', () {
      expect(mapRelayStatus('queued_ephemeral'), 'sent');
    });

    test('passes through known app statuses', () {
      for (final s in ['sent', 'delivered', 'read', 'failed', 'expired']) {
        expect(mapRelayStatus(s), s);
      }
    });

    test('returns null for unknown statuses (no silent read claim)', () {
      expect(mapRelayStatus('something_new'), isNull);
      expect(mapRelayStatus(''), isNull);
    });
  });

  group('buildChatId', () {
    test('is order independent and stable', () {
      expect(buildChatId('a', 'b'), buildChatId('b', 'a'));
      expect(buildChatId('a', 'b'), 'a_b');
    });
  });

  group('formatListTimestamp', () {
    final now = DateTime(2026, 9, 22, 15, 30);

    test('empty for zero/invalid timestamps', () {
      expect(formatListTimestamp(0, now: now), '');
    });

    test('today shows a clock time', () {
      final t = DateTime(2026, 9, 22, 9, 5).millisecondsSinceEpoch;
      expect(formatListTimestamp(t, now: now), '9:05 AM');
    });

    test('yesterday is labelled', () {
      final t = DateTime(2026, 9, 21, 23, 0).millisecondsSinceEpoch;
      expect(formatListTimestamp(t, now: now), 'Yesterday');
    });

    test('within a week shows the weekday', () {
      final t = DateTime(2026, 9, 19, 12, 0).millisecondsSinceEpoch; // Sat
      expect(formatListTimestamp(t, now: now), 'Sat');
    });

    test('older this year shows month + day', () {
      final t = DateTime(2026, 3, 4, 12, 0).millisecondsSinceEpoch;
      expect(formatListTimestamp(t, now: now), 'Mar 4');
    });

    test('previous years show a short date', () {
      final t = DateTime(2025, 3, 4, 12, 0).millisecondsSinceEpoch;
      expect(formatListTimestamp(t, now: now), '03/04/25');
    });
  });
}
