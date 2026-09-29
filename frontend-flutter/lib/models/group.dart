import 'dart:convert';

/// Which group-key scheme a group uses.
///
/// Groups created before MLS existed carry [legacySharedKey]: one symmetric
/// ChaCha20-Poly1305 key shared by every member, rotated by broadcasting a new
/// key. That construction has no forward secrecy and no post-compromise
/// security, and any member who ever held the key keeps the ability to read
/// every message encrypted under it — including messages sent after they were
/// removed, if they kept the rotated key out of the fan-out.
///
/// [mls] groups derive keys through RFC 9420 instead, so the ratchet tree gives
/// real forward secrecy and heals after a compromise.
///
/// This value lives in group state and is advertised in group-control messages,
/// so a client only sends MLS material to peers that understand it.
class GroupCrypto {
  const GroupCrypto._();

  /// Shared symmetric key, `groups.group_key`. Legacy read path.
  static const int legacySharedKey = 1;

  /// RFC 9420 MLS (OpenMLS).
  static const int mls = 2;

  /// Whether a group at [cryptoVersion] is keyed by MLS.
  static bool usesMls(int cryptoVersion) => cryptoVersion >= mls;

  /// The version a brand-new group is created with.
  ///
  /// New groups are MLS. Existing groups are never rewritten in place: a shared
  /// key cannot be converted into an MLS epoch, and silently re-keying one
  /// would lock out every member still running a released build.
  static const int current = mls;
}

/// Whether a group-control message advertising [incomingVersion] may be applied
/// on top of local state at [localVersion].
///
/// `group_invite` / `group_add` carry a fresh `groupKey`. The relay is
/// unordered and replayable, so an *old* instance of either can arrive after a
/// newer one. Applying it would silently restore a **superseded** group key —
/// undoing exactly the rotation that was supposed to revoke a removed member.
/// A generation that is not newer than what is already held is therefore
/// dropped.
///
/// A `null` version comes from a client built before versioning existed; it is
/// still accepted so the rollout does not break already-shipped groups.
bool acceptsControlVersion({
  required int localVersion,
  required int? incomingVersion,
}) {
  if (incomingVersion == null) return true;
  return incomingVersion > localVersion;
}

class Group {
  final String id;
  final String name;
  final List<String> memberUids;
  final int createdAt;
  final String? groupKey; // base64-encoded symmetric ChaCha20-Poly1305 key

  /// Monotonic generation of the group key, incremented on every rotation.
  /// Lets a receiver reject a stale replayed key. 0 = pre-versioning record.
  final int keyVersion;

  /// Which group-key scheme this group uses — see [GroupCrypto].
  ///
  /// Defaults to [GroupCrypto.legacySharedKey]: a group is only MLS when it was
  /// created as MLS, so existing groups keep working unchanged.
  final int cryptoVersion;

  final int unreadCount;

  Group({
    required this.id,
    required this.name,
    required this.memberUids,
    required this.createdAt,
    this.groupKey,
    this.keyVersion = 0,
    this.cryptoVersion = GroupCrypto.legacySharedKey,
    this.unreadCount = 0,
  });

  /// Whether this group is keyed by MLS rather than the shared-key scheme.
  bool get usesMls => GroupCrypto.usesMls(cryptoVersion);

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'member_uids': jsonEncode(memberUids),
    'created_at': createdAt,
    'group_key': groupKey,
    'key_version': keyVersion,
    'crypto_version': cryptoVersion,
    'unread_count': unreadCount,
  };

  factory Group.fromMap(Map<String, dynamic> map) => Group(
    id: map['id'] as String,
    name: map['name'] as String,
    memberUids: _decodeUids(map['member_uids']),
    createdAt: map['created_at'] as int? ?? 0,
    groupKey: map['group_key'] as String?,
    keyVersion: map['key_version'] as int? ?? 0,
    cryptoVersion: map['crypto_version'] as int? ?? GroupCrypto.legacySharedKey,
    unreadCount: map['unread_count'] as int? ?? 0,
  );

  static List<String> _decodeUids(dynamic v) {
    if (v == null) return [];
    if (v is String) {
      try {
        final d = jsonDecode(v);
        if (d is List) return d.cast<String>();
      } catch (_) {}
      return [];
    }
    if (v is List) return v.cast<String>();
    return [];
  }

  Group copyWith({
    String? name,
    List<String>? memberUids,
    String? groupKey,
    int? keyVersion,
    int? cryptoVersion,
    int? unreadCount,
  }) => Group(
    id: id,
    name: name ?? this.name,
    memberUids: memberUids ?? this.memberUids,
    createdAt: createdAt,
    groupKey: groupKey ?? this.groupKey,
    keyVersion: keyVersion ?? this.keyVersion,
    cryptoVersion: cryptoVersion ?? this.cryptoVersion,
    unreadCount: unreadCount ?? this.unreadCount,
  );
}
