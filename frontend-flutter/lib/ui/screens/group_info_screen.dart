import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/database/daos/contact_dao.dart';
import '../../core/theme/colors.dart';
import '../../models/contact.dart';
import '../../models/group.dart';
import '../../state/group_provider.dart';

class GroupInfoScreen extends ConsumerStatefulWidget {
  final Group group;
  const GroupInfoScreen({Key? key, required this.group}) : super(key: key);
  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  late Group _group;
  List<Contact> _members = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _group = widget.group; _load(); }

  Future<void> _load() async {
    final g = await ref.read(groupDaoProvider).getGroupById(_group.id) ?? _group;
    _group = g;
    final members = <Contact>[];
    for (final uid in g.memberUids) {
      final c = await ContactDao().getContactByUid(uid);
      members.add(c ?? Contact(uid: uid, username: 'peer_${uid.length > 8 ? uid.substring(uid.length - 8) : uid}', identityPublicKey: '', createdAt: 0));
    }
    if (mounted) setState(() {_members = members; _loading = false;});
  }

  Future<void> _addMembers() async {
    final all = await ContactDao().getAllContacts();
    final notIn = all.where((c) => !_group.memberUids.contains(c.uid)).toList();
    if (notIn.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No contacts to add')));
      return;
    }
    final picked = <String>{};
    final result = await showDialog<Set<String>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
      backgroundColor: AirColors.surface,
      title: const Text('Add members', style: TextStyle(color: AirColors.textPrimary)),
      content: SizedBox(width: double.maxFinite, height: 300, child: ListView.builder(itemCount: notIn.length, itemBuilder: (_, i) {
        final c = notIn[i];
        return CheckboxListTile(value: picked.contains(c.uid), onChanged: (v) => setS(() => v! ? picked.add(c.uid) : picked.remove(c.uid)), title: Text(c.username, style: const TextStyle(color: AirColors.textPrimary)), activeColor: AirColors.accent, checkColor: AirColors.background);
      })),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, picked), child: const Text('Add'))],
    )));
    if (result == null || result.isEmpty) return;
    await ref.read(groupActionsProvider).addMembers(_group.id, result.toList());
    await _load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Members added')));
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(backgroundColor: AirColors.surface, title: const Text('Leave group?', style: TextStyle(color: AirColors.textPrimary)), content: const Text('You will no longer receive messages from this group.', style: TextStyle(color: AirColors.textSecondary)), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave', style: TextStyle(color: AirColors.error))) ]));
    if (ok != true) return;
    await ref.read(groupActionsProvider).leaveGroup(_group.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('MMM d, yyyy').format(DateTime.fromMillisecondsSinceEpoch(_group.createdAt));
    return Scaffold(
      backgroundColor: AirColors.background,
      appBar: AppBar(title: const Text('Group info', style: TextStyle(color: AirColors.textPrimary)), backgroundColor: AirColors.surface),
      body: _loading ? const Center(child: CircularProgressIndicator(color: AirColors.accent, strokeWidth: 2)) : ListView(children: [
        const SizedBox(height: 24),
        Center(child: Container(width: 72, height: 72, alignment: Alignment.center, decoration: BoxDecoration(shape: BoxShape.circle, color: AirColors.surfaceLight, border: Border.all(color: AirColors.border)), child: Text(_group.name.isNotEmpty ? _group.name[0].toUpperCase() : 'G', style: const TextStyle(color: AirColors.textPrimary, fontSize: 28, fontWeight: FontWeight.w600)))),
        const SizedBox(height: 12),
        Center(child: Text(_group.name, style: const TextStyle(color: AirColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w700))),
        const SizedBox(height: 4),
        Center(child: Text('Created $date • ${_group.memberUids.length} members', style: const TextStyle(color: AirColors.textSecondary, fontSize: 13))),
        const SizedBox(height: 24),
        const Divider(color: AirColors.divider, height: 1),
        ListTile(leading: const Icon(Icons.person_add, color: AirColors.accent), title: const Text('Add member', style: TextStyle(color: AirColors.accent)), onTap: _addMembers),
        const Divider(color: AirColors.divider, height: 1),
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 6), child: Text('Members (${_members.length})', style: const TextStyle(color: AirColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w600))),
        ..._members.map((c) => ListTile(leading: CircleAvatar(backgroundColor: AirColors.surfaceLight, child: Text(c.username.isNotEmpty ? c.username[0].toUpperCase() : '?', style: const TextStyle(color: AirColors.textPrimary))), title: Text(c.username, style: const TextStyle(color: AirColors.textPrimary)), subtitle: Text(c.uid, style: const TextStyle(color: AirColors.textFaint, fontSize: 11)))),
        const SizedBox(height: 24),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: SizedBox(width: double.infinity, child: OutlinedButton.icon(icon: const Icon(Icons.exit_to_app, color: AirColors.error, size: 18), label: const Text('Leave group', style: TextStyle(color: AirColors.error)), style: OutlinedButton.styleFrom(side: const BorderSide(color: AirColors.error), padding: const EdgeInsets.symmetric(vertical: 14)), onPressed: _leave))),
        const SizedBox(height: 32),
      ]),
    );
  }
}
