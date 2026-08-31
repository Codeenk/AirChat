class Contact {
  final String uid;
  final String username;
  final String identityPublicKey;
  final int createdAt;

  Contact({
    required this.uid,
    required this.username,
    required this.identityPublicKey,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'uid': uid,
    'username': username,
    'identity_public_key': identityPublicKey,
    'created_at': createdAt,
  };

  factory Contact.fromMap(Map<String, dynamic> map) => Contact(
    uid: map['uid'],
    username: map['username'],
    identityPublicKey: map['identity_public_key'],
    createdAt: map['created_at'],
  );
}
