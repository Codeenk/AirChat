import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_thread.dart';
import '../models/group.dart';
import 'connection_provider.dart';
import 'group_provider.dart';

/// One row on the home screen — either a 1:1 thread or a group, unified so the
/// list can be sorted purely by recency instead of "groups always on top".
class HomeEntry {
  final bool isGroup;
  final ChatThread? chat;
  final Group? group;
  final int lastActivity;
  final String preview;
  final int unread;

  const HomeEntry({
    required this.isGroup,
    this.chat,
    this.group,
    required this.lastActivity,
    required this.preview,
    required this.unread,
  });

  String get id => isGroup ? group!.id : chat!.id;

  String get title => isGroup
      ? group!.name
      : (chat!.contactUsername.isNotEmpty ? chat!.contactUsername : 'Peer');

  String get subtitle {
    if (preview.isNotEmpty) return preview;
    if (isGroup) return '${group!.memberUids.length} members';
    return 'No messages yet';
  }
}

/// Reactive home feed: merges groups + 1:1 threads and re-emits on every bus
/// event so previews, ordering and badges all update live.
final homeEntriesProvider = StreamProvider.autoDispose<List<HomeEntry>>((
  ref,
) async* {
  final chatDao = ref.watch(chatDaoProvider);
  final groupDao = ref.watch(groupDaoProvider);

  Future<List<HomeEntry>> load() async {
    final threads = await chatDao.getAllChatsWithContacts();
    final groups = await groupDao.getAllGroups();
    final activity = await groupDao.getLastActivity();

    final entries = <HomeEntry>[];
    for (final g in groups) {
      final act = activity[g.id];
      entries.add(
        HomeEntry(
          isGroup: true,
          group: g,
          lastActivity: act?.timestamp ?? g.createdAt,
          preview: act?.preview ?? '',
          unread: g.unreadCount,
        ),
      );
    }
    for (final t in threads) {
      entries.add(
        HomeEntry(
          isGroup: false,
          chat: t,
          lastActivity: t.lastMessageTime,
          preview: t.lastMessage,
          unread: t.unreadCount,
        ),
      );
    }
    entries.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
    return entries;
  }

  yield await load();
  await for (final _ in ref.watch(refreshBusProvider).stream) {
    yield await load();
  }
});
