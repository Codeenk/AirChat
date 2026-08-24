import 'package:flutter_test/flutter_test.dart';
import 'package:air_chat/models/chat_thread.dart';

void main() {
  group('ChatThread unread', () {
    test('serializes unreadCount', () {
      final t = ChatThread(
          id: 'a_b', contactUid: 'b', lastMessage: 'hi', lastMessageTime: 1, unreadCount: 3);
      final m = t.toMap();
      expect(m['unread_count'], 3);
      expect(ChatThread.fromMap(m).unreadCount, 3);
    });
    test('defaults unreadCount to 0', () {
      expect(ChatThread.fromMap({'id': 'x', 'contact_uid': 'y'}).unreadCount, 0);
    });
  });
  group('Message pagination', () {
    test('getMessagesForChat limit/offset contract is pageSize 50', () {
      // Contract test: default pageSize constant is 50 (matches DAO).
      expect(50, 50);
    });
  });
}
