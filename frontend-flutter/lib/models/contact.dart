class Contact {
  final String uid;
  final String username;
  final String identityPublicKey;
  final String? signingPublicKey;
  final int createdAt;

  /// Peer keys as they were at the moment the user compared the safety number
  /// and confirmed it. Storing the *verified* values (rather than a boolean) is
  /// what makes a later key change detectable instead of silent: if the peer's
  /// live keys stop matching these, the verification is void and the user is
  /// told, rather than the badge quietly staying green.
  final String? verifiedIdentityKey;
  final String? verifiedSigningKey;
  final int? verifiedAt;

  Contact({
    required this.uid,
    required this.username,
    required this.identityPublicKey,
    this.signingPublicKey,
    required this.createdAt,
    this.verifiedIdentityKey,
    this.verifiedSigningKey,
    this.verifiedAt,
  });

  /// Base columns only. Verification columns are deliberately excluded: they are
  /// written exclusively through [ContactDao.markVerified] /
  /// [ContactDao.clearVerification] so that a routine contact refresh (which
  /// happens on every directory lookup) can never wipe them.
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
    verifiedIdentityKey: map['verified_identity_key'] as String?,
    verifiedSigningKey: map['verified_signing_key'] as String?,
    verifiedAt: map['verified_at'] as int?,
  );

  /// True when the user has compared the safety number and both of the peer's
  /// keys still match what they verified.
  ///
  /// Can only be true once both keys are known — the safety number covers the
  /// signing key too, so there is nothing to have verified without it.
  bool get isVerified =>
      verifiedIdentityKey != null &&
      verifiedIdentityKey == identityPublicKey &&
      normalizedSigningKey != null &&
      normalizedSigningKey == normalizedVerifiedSigningKey;

  /// The dangerous state: keys *were* verified and no longer match. Either the
  /// peer reinstalled, or the directory is serving different keys than the ones
  /// the user confirmed in person — which is exactly the MITM this feature
  /// exists to catch.
  bool get hasKeyChanged => verifiedIdentityKey != null && !isVerified;

  bool get isVerificationRecorded => verifiedIdentityKey != null;

  /// Signing keys are hex, and hex is case-insensitive. Normalising before
  /// comparison keeps an uppercase code scanned in person from being reported as
  /// a key change against a lowercase directory value — the same key must never
  /// read as two.
  String? get normalizedSigningKey => normalizeSigningKey(signingPublicKey);

  String? get normalizedVerifiedSigningKey =>
      normalizeSigningKey(verifiedSigningKey);

  static String? normalizeSigningKey(String? value) {
    // Strip *all* whitespace, not just the ends: the same reasoning as the
    // safety number's transcript encoding — a key that differs only in layout
    // must not read as a different key.
    final cleaned = value?.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (cleaned == null || cleaned.isEmpty) return null;
    return cleaned;
  }

  Contact copyWith({
    String? username,
    String? identityPublicKey,
    String? signingPublicKey,
    String? verifiedIdentityKey,
    String? verifiedSigningKey,
    int? verifiedAt,
  }) => Contact(
    uid: uid,
    username: username ?? this.username,
    identityPublicKey: identityPublicKey ?? this.identityPublicKey,
    signingPublicKey: signingPublicKey ?? this.signingPublicKey,
    createdAt: createdAt,
    verifiedIdentityKey: verifiedIdentityKey ?? this.verifiedIdentityKey,
    verifiedSigningKey: verifiedSigningKey ?? this.verifiedSigningKey,
    verifiedAt: verifiedAt ?? this.verifiedAt,
  );
}
