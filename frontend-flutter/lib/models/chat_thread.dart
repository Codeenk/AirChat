class ChatThread {
  final String id;
  final String contactUid;
  final String lastMessage;
  final int lastMessageTime;
  final int unreadCount;
  final String contactUsername;

  ChatThread({
    required this.id,
    required this.contactUid,
    required this.lastMessage,
    required this.lastMessageTime,
    this.unreadCount = 0,
    this.contactUsername = '',
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'contact_uid': contactUid,
    'last_message': lastMessage,
    'last_message_time': lastMessageTime,
    'unread_count': unreadCount,
  };

  factory ChatThread.fromMap(Map<String, dynamic> map) => ChatThread(
    id: map['id'],
    contactUid: map['contact_uid'],
    lastMessage: map['last_message'] ?? '',
    lastMessageTime: map['last_message_time'] ?? 0,
    unreadCount: map['unread_count'] ?? 0,
    contactUsername: map['contact_username'] ?? '',
  );
}
