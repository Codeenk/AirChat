import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/daos/contact_dao.dart';
import '../../core/theme/colors.dart';
import '../../models/contact.dart';
import '../../state/group_provider.dart';
import 'group_chat_screen.dart';

class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({Key? key}) : super(key: key);
  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _nameCtrl = TextEditingController();
  final _selected = <String>{};
  List<Contact> _contacts = [];
  bool _loading = true;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = await ContactDao().getAllContacts();
    if (mounted)
      setState(() {
        _contacts = c;
        _loading = false;
      });
  }

  Future<void> _create() async {
    if (_selected.isEmpty || _creating) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter group name')));
      return;
    }
    setState(() => _creating = true);
    try {
      final group = await ref
          .read(groupActionsProvider)
          .createGroup(name: name, memberUids: _selected.toList());
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => GroupChatScreen(group: group)),
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AirColors.background,
      appBar: AppBar(
        title: const Text(
          'New Group',
          style: TextStyle(color: AirColors.textPrimary),
        ),
        backgroundColor: AirColors.surface,
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                color: AirColors.accent,
                strokeWidth: 2,
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _nameCtrl,
                    style: const TextStyle(color: AirColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Group name',
                      hintStyle: const TextStyle(color: AirColors.textFaint),
                      filled: true,
                      fillColor: AirColors.surfaceLight,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _contacts.length,
                    itemBuilder: (_, i) {
                      final c = _contacts[i];
                      final sel = _selected.contains(c.uid);
                      return CheckboxListTile(
                        value: sel,
                        onChanged: (v) => setState(
                          () => v!
                              ? _selected.add(c.uid)
                              : _selected.remove(c.uid),
                        ),
                        title: Text(
                          c.username,
                          style: const TextStyle(color: AirColors.textPrimary),
                        ),
                        secondary: CircleAvatar(
                          backgroundColor: AirColors.surfaceLight,
                          child: Text(
                            c.username.isNotEmpty
                                ? c.username[0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              color: AirColors.textPrimary,
                            ),
                          ),
                        ),
                        activeColor: AirColors.accent,
                        checkColor: AirColors.background,
                      );
                    },
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _selected.isEmpty || _creating
                            ? null
                            : _create,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AirColors.bubbleMe,
                          foregroundColor: AirColors.bubbleMeText,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _creating
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text('Create (${_selected.length})'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
