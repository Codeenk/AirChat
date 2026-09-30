/// Which key-agreement scheme a 1:1 chat uses.
///
/// A chat is created with [legacyX25519] and is only ever moved to
/// [doubleRatchet] at the moment it is first created against a peer that
/// publishes a libsignal prekey bundle. It is never rewritten afterwards:
/// switching mid-conversation would leave the peer unable to decrypt whichever
/// messages crossed the switch, and a released client that cannot speak the
/// ratchet at all must keep working on chats it already has.
///
/// This is the 1:1 counterpart of `GroupCrypto` in `lib/models/group.dart`.
class ChatCrypto {
  const ChatCrypto._();

  /// X25519 against the recipient's long-term key. No forward secrecy — see
  /// SECURITY_DESIGN.md §3.1. Legacy read path.
  static const int legacyX25519 = 1;

  /// libsignal Double Ratchet (X3DH/PQXDH + symmetric ratchet).
  static const int doubleRatchet = 2;

  /// Whether a chat at [cryptoVersion] is keyed by the Double Ratchet.
  static bool usesRatchet(int cryptoVersion) => cryptoVersion >= doubleRatchet;

  /// The scheme a brand-new chat starts on. The ratchet is only used when the
  /// peer's published bundle has actually been fetched, so the *effective*
  /// initial value for two upgraded devices is [doubleRatchet] — this constant
  /// is just the storage default.
  static const int current = legacyX25519;
}

class ChatThread {
  final String id;
  final String contactUid;
  final String lastMessage;
  final int lastMessageTime;
  final int unreadCount;
  final String contactUsername;

  /// Which scheme this chat uses — see [ChatCrypto]. Defaults to the legacy
  /// path so every chat that already exists keeps the scheme it was created
  /// with.
  final int cryptoVersion;

  ChatThread({
    required this.id,
    required this.contactUid,
    required this.lastMessage,
    required this.lastMessageTime,
    this.unreadCount = 0,
    this.contactUsername = '',
    this.cryptoVersion = ChatCrypto.legacyX25519,
  });

  /// Whether this chat is on the Double Ratchet rather than the legacy path.
  bool get usesRatchet => ChatCrypto.usesRatchet(cryptoVersion);

  Map<String, dynamic> toMap() => {
    'id': id,
    'contact_uid': contactUid,
    'last_message': lastMessage,
    'last_message_time': lastMessageTime,
    'unread_count': unreadCount,
    'crypto_version': cryptoVersion,
  };

  factory ChatThread.fromMap(Map<String, dynamic> map) => ChatThread(
    id: map['id'],
    contactUid: map['contact_uid'],
    lastMessage: map['last_message'] ?? '',
    lastMessageTime: map['last_message_time'] ?? 0,
    unreadCount: map['unread_count'] ?? 0,
    contactUsername: map['contact_username'] ?? '',
    cryptoVersion: map['crypto_version'] as int? ?? ChatCrypto.legacyX25519,
  );

  ChatThread copyWith({
    String? lastMessage,
    int? lastMessageTime,
    int? unreadCount,
    int? cryptoVersion,
  }) => ChatThread(
    id: id,
    contactUid: contactUid,
    lastMessage: lastMessage ?? this.lastMessage,
    lastMessageTime: lastMessageTime ?? this.lastMessageTime,
    unreadCount: unreadCount ?? this.unreadCount,
    contactUsername: contactUsername,
    cryptoVersion: cryptoVersion ?? this.cryptoVersion,
  );
}
