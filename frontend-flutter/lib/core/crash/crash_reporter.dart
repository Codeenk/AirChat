import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

/// Privacy-friendly, fully local crash/error log.
///
/// Appends one JSON line per event to `airchat_diagnostics.jsonl` in the
/// app's documents directory. The log is capped (~200 KB) by truncating the
/// oldest half when it grows too large. Nothing ever leaves the device.
class CrashReporter {
  CrashReporter._();

  static const int _maxLogBytes = 200 * 1024;
  static const String _fileName = 'airchat_diagnostics.jsonl';
  static const String _appVersion = '1.2.0';

  static File? _logFile;
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized || kIsWeb) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFile = File('${dir.path}/$_fileName');
      _initialized = true;
    } catch (_) {
      // Storage unavailable — logging becomes a no-op.
    }
  }

  static void recordError({
    required Object error,
    StackTrace? stackTrace,
    String? source,
  }) {
    _appendLine(jsonEncode({
      'ts': DateTime.now().toUtc().toIso8601String(),
      'version': _appVersion,
      if (source != null) 'source': source,
      'error': error.toString(),
      if (stackTrace != null) 'stack': stackTrace.toString().split('\n').take(24).join('\n'),
    }));
  }

  static void recordLog(String message) {
    _appendLine(jsonEncode({
      'ts': DateTime.now().toUtc().toIso8601String(),
      'version': _appVersion,
      'log': message,
    }));
  }

  /// Full diagnostics content for the future "Export diagnostics" button.
  static Future<String> readAll() async {
    final file = _logFile;
    if (file == null || !await file.exists()) return '';
    try {
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  static void _appendLine(String line) {
    final file = _logFile;
    if (file == null) return;
    try {
      // Fire-and-forget; never let logging crash the app.
      unawaited(() async {
        try {
          final sink = file.openWrite(mode: FileMode.append);
          sink.writeln(line);
          await sink.flush();
          await sink.close();
          await _truncateIfNeeded(file);
        } catch (_) {}
      }());
    } catch (_) {}
  }

  static Future<void> _truncateIfNeeded(File file) async {
    final length = await file.length();
    if (length <= _maxLogBytes) return;
    final lines = await file.readAsLines();
    // Keep the newest half of the lines.
    final keep = lines.skip(lines.length ~/ 2).toList();
    await file.writeAsString(keep.join('\n') + '\n');
  }
}
