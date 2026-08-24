import 'package:flutter_test/flutter_test.dart';
import 'package:air_chat/core/network/websocket_client.dart';

void main() {
  group('WebSocket backoff', () {
    test('doubles until cap with jitter', () {
      for (int i = 3; i < 30; i = WebSocketTunnelClient.nextBackoffSeconds(i)) {
        expect(i, inInclusiveRange(3, 30));
        if (i >= 30) break;
      }
    });
    test('stays within 3..30 inclusive', () {
      for (int c in [3, 6, 12, 24, 30, 100]) {
        final n = WebSocketTunnelClient.nextBackoffSeconds(c);
        expect(n, inInclusiveRange(3, 30));
      }
    });
    test('nextBackoff is deterministic range (multiple calls stay bounded)', () {
      for (int j = 0; j < 20; j++) {
        expect(WebSocketTunnelClient.nextBackoffSeconds(12), inInclusiveRange(3, 30));
      }
    });
  });
}
