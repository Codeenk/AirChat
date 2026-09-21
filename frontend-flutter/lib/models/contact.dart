class Contact {
  final String uid;
  final String username;
  final String identityPublicKey;
  final String? signingPublicKey;
  final int createdAt;

  Contact({
    required this.uid,
    required this.username,
    required this.identityPublicKey,
    this.signingPublicKey,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'uid': uid,
    'username': username,
    'identity_public_key': identityPublicKey,
    'signing_public_key': signingPublicKey,
    'created_at': createdAt,
  };

  factory Contact.fromMap(Map<String, dynamic> map) => Contact(
    uid: map['uid'],
    username: map['username'],
    identityPublicKey: map['identity_public_key'],
    signingPublicKey: map['signing_public_key'] as String?,
    createdAt: map['created_at'],
  );
}
