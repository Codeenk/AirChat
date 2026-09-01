import 'dart:convert';

class Group {
  final String id;
  final String name;
  final List<String> memberUids;
  final int createdAt;
  final String? groupKey; // base64-encoded symmetric ChaCha20-Poly1305 key

  Group({
    required this.id,
    required this.name,
    required this.memberUids,
    required this.createdAt,
    this.groupKey,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'member_uids': jsonEncode(memberUids),
    'created_at': createdAt,
    'group_key': groupKey,
  };

  factory Group.fromMap(Map<String, dynamic> map) => Group(
    id: map['id'] as String,
    name: map['name'] as String,
    memberUids: _decodeUids(map['member_uids']),
    createdAt: map['created_at'] as int? ?? 0,
    groupKey: map['group_key'] as String?,
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

  Group copyWith({String? name, List<String>? memberUids, String? groupKey}) => Group(
    id: id,
    name: name ?? this.name,
    memberUids: memberUids ?? this.memberUids,
    createdAt: createdAt,
    groupKey: groupKey ?? this.groupKey,
  );
}
