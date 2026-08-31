import 'dart:convert';

class Group {
  final String id;
  final String name;
  final List<String> memberUids;
  final int createdAt;

  Group({
    required this.id,
    required this.name,
    required this.memberUids,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'member_uids': jsonEncode(memberUids),
    'created_at': createdAt,
  };

  factory Group.fromMap(Map<String, dynamic> map) => Group(
    id: map['id'] as String,
    name: map['name'] as String,
    memberUids: _decodeUids(map['member_uids']),
    createdAt: map['created_at'] as int? ?? 0,
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

  Group copyWith({String? name, List<String>? memberUids}) => Group(
    id: id,
    name: name ?? this.name,
    memberUids: memberUids ?? this.memberUids,
    createdAt: createdAt,
  );
}
