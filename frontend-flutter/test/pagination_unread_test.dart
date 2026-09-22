import 'package:flutter_test/flutter_test.dart';
import 'package:air_chat/models/chat_thread.dart';
import 'package:air_chat/models/message_payload.dart';

void main() {
  group('ChatThread unread', () {
    test('serializes unreadCount', () {
      final t = ChatThread(
        id: 'a_b',
        contactUid: 'b',
        lastMessage: 'hi',
        lastMessageTime: 1,
        unreadCount: 3,
      );
      final m = t.toMap();
      expect(m['unread_count'], 3);
      expect(ChatThread.fromMap(m).unreadCount, 3);
    });

    test('defaults unreadCount to 0', () {
      expect(
        ChatThread.fromMap({'id': 'x', 'contact_uid': 'y'}).unreadCount,
        0,
      );
    });
  });

  group('ChatMessage serialization', () {
    test('round-trips a reply + media message', () {
      final msg = ChatMessage(
        id: 'p1',
        chatId: 'a_b',
        senderUid: 'a',
        recipientUid: 'b',
        text: 'photo.jpg',
        mediaKey: 'file.enc',
        secretKeyHex: 'aa',
        nonceHex: 'bb',
        type: 'image',
        timestamp: 123,
        isMe: true,
        status: 'sent',
        replyToId: 'p0',
        replyText: 'original',
        replyType: 'text',
        replyIsMe: false,
        groupId: null,
        groupSenderName: null,
      );
      final map = msg.toMap();
      final back = ChatMessage.fromMap(map);
      expect(back.id, msg.id);
      expect(back.mediaKey, 'file.enc');
      expect(back.hasReply, isTrue);
      expect(back.replyText, 'original');
      expect(back.isMe, isTrue);
      expect(back.status, 'sent');
    });

    test('hasReply is false without a reply id', () {
      final msg = ChatMessage(
        id: 'p2',
        chatId: 'c',
        senderUid: 'a',
        recipientUid: 'b',
        text: 'x',
        timestamp: 1,
        isMe: false,
      );
      expect(msg.hasReply, isFalse);
    });
  });
}
