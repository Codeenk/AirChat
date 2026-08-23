class ChatMessage {
  final String id;
  final String chatId;
  final String senderUid;
  final String recipientUid;
  final String text;
  final String? mediaKey;
  final String? secretKeyHex;
  final String? nonceHex;
  final String type; // 'text', 'image', 'voice', 'document'
  final int timestamp;
  final bool isMe;
  final String status; // 'sending', 'sent', 'delivered', 'read'

  ChatMessage({
    required this.id,
    required this.chatId,
    required this.senderUid,
    required this.recipientUid,
    required this.text,
    this.mediaKey,
    this.secretKeyHex,
    this.nonceHex,
    this.type = 'text',
    required this.timestamp,
    required this.isMe,
    this.status = 'sent',
  });

  ChatMessage copyWith({String? status}) => ChatMessage(
        id: id,
        chatId: chatId,
        senderUid: senderUid,
        recipientUid: recipientUid,
        text: text,
        mediaKey: mediaKey,
        secretKeyHex: secretKeyHex,
        nonceHex: nonceHex,
        type: type,
        timestamp: timestamp,
        isMe: isMe,
        status: status ?? this.status,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'chat_id': chatId,
        'sender_uid': senderUid,
        'recipient_uid': recipientUid,
        'text': text,
        'media_key': mediaKey,
        'secret_key_hex': secretKeyHex,
        'nonce_hex': nonceHex,
        'type': type,
        'timestamp': timestamp,
        'is_me': isMe ? 1 : 0,
        'status': status,
      };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
        id: map['id'],
        chatId: map['chat_id'],
        senderUid: map['sender_uid'],
        recipientUid: map['recipient_uid'],
        text: map['text'] ?? '',
        mediaKey: map['media_key'],
        secretKeyHex: map['secret_key_hex'],
        nonceHex: map['nonce_hex'],
        type: map['type'] ?? 'text',
        timestamp: map['timestamp'] ?? 0,
        isMe: (map['is_me'] ?? 0) == 1,
        status: map['status'] ?? 'sent',
      );
}
