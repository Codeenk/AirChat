import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:package_info_plus/package_info_plus.dart';
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
  static String _appVersion = 'unknown';

  static File? _logFile;
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized || kIsWeb) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = info.version;
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
    _appendLine(
      jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'version': _appVersion,
        if (source != null) 'source': source,
        'error': _redactError(error.toString()),
        if (stackTrace != null)
          'stack': _redactStack(stackTrace.toString()),
      }),
    );
  }

  static void recordLog(String message) {
    _appendLine(
      jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'version': _appVersion,
        'log': _redactError(message),
      }),
    );
  }

  /// Minimal redaction helpers for local diagnostic logs. These are not crypto
  /// boundaries; they just keep log lines short and avoid dumping raw network/
  /// relay objects into crash logs.
  static String _redactError(String s) {
    if (s.length <= 200) return s;
    return s.substring(0, 200);
  }

  static String _redactStack(String s) {
    final lines = s.split('\n');
    if (lines.length <= 12) return s;
    return lines.take(12).join('\n');
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
