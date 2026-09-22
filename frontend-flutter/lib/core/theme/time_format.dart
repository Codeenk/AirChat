import 'package:intl/intl.dart';

/// Formats a chat-list timestamp the way messaging apps do:
/// today → "3:42 PM", yesterday → "Yesterday", this week → "Tue",
/// this year → "Mar 4", older → "03/04/25".
///
/// Pure (no `DateTime.now()` unless [now] is omitted) so it can be tested.
String formatListTimestamp(int millisecondsSinceEpoch, {DateTime? now}) {
  if (millisecondsSinceEpoch <= 0) return '';
  final n = now ?? DateTime.now();
  final d = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
  final today = DateTime(n.year, n.month, n.day);
  final that = DateTime(d.year, d.month, d.day);
  final diff = today.difference(that).inDays;

  if (diff <= 0) return DateFormat('h:mm a').format(d);
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return DateFormat('EEE').format(d);
  if (d.year == n.year) return DateFormat('MMM d').format(d);
  return DateFormat('MM/dd/yy').format(d);
}
