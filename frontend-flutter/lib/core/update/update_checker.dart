import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateInfo {
  final String latestTag;
  final String normalizedVersion;
  final String htmlUrl;
  final String body;
  final String downloadUrl;

  const UpdateInfo({
    required this.latestTag,
    required this.normalizedVersion,
    required this.htmlUrl,
    required this.body,
    required this.downloadUrl,
  });
}

class UpdateChecker {
  static const String _apiUrl =
      'https://api.github.com/repos/Codeenk/AirChat/releases/latest';
  static const String _seenKey = 'airchat_seen_release_tag';
  static const _storage = FlutterSecureStorage();

  /// Returns update info when a newer release exists, null otherwise.
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = _normalize(info.version);

      final res = await http
          .get(Uri.parse(_apiUrl),
              headers: {'Accept': 'application/vnd.github.v3+json'})
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?) ?? '';
      final htmlUrl = (json['html_url'] as String?) ?? '';
      final body = (json['body'] as String?) ?? '';
      if (tag.isEmpty) return null;

      final latest = _normalize(tag);
      if (!_isNewer(latest, current)) return null;

      String downloadUrl = htmlUrl;
      final assets = json['assets'] as List<dynamic>?;
      if (assets != null) {
        for (final a in assets) {
          final name = (a as Map<String, dynamic>)['name'] as String? ?? '';
          if (name.contains('arm64')) {
            downloadUrl = a['browser_download_url'] as String? ?? htmlUrl;
            break;
          }
        }
      }

      return UpdateInfo(
        latestTag: tag,
        normalizedVersion: latest,
        htmlUrl: htmlUrl,
        body: body,
        downloadUrl: downloadUrl,
      );
    } catch (_) {
      return null;
    }
  }

  /// True only the first time the app runs on a given version — drives the
  /// one-time "What's new" dialog for the current (latest) release.
  static Future<bool> isFirstRunOfVersion(String installedVersion) async {
    final normalized = _normalize(installedVersion);
    final seen = await _storage.read(key: _seenKey);
    if (seen == normalized) return false;
    await _storage.write(key: _seenKey, value: normalized);
    return true;
  }

  /// Streams the APK to app-specific external storage with progress 0.0–1.0,
  /// then hands the file to the Android package installer.
  static Future<bool> downloadAndInstall(
      UpdateInfo info, void Function(double progress) onProgress) async {
    http.Client? client;
    try {
      client = http.Client();
      final res =
          await client.send(http.Request('GET', Uri.parse(info.downloadUrl)));
      if (res.statusCode != 200) return false;

      final total = res.contentLength ?? 0;
      final dir = await _downloadDir();
      final file =
          File('${dir.path}/airchat_update_${info.normalizedVersion}.apk');
      final sink = file.openWrite();

      var received = 0;
      await for (final chunk in res.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress(received / total);
      }
      await sink.flush();
      await sink.close();

      final result = await OpenFilex.open(file.path,
          type: 'application/vnd.android.package-archive');
      return result.type == ResultType.done;
    } catch (_) {
      return false;
    } finally {
      client?.close();
    }
  }

  static Future<void> openRelease(UpdateInfo info) async {
    final uri = Uri.parse(info.htmlUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// App-specific external dir — no storage permission required, and the
  /// package installer can read it.
  static Future<Directory> _downloadDir() async {
    if (Platform.isAndroid) {
      try {
        final dir = await getExternalStorageDirectory();
        if (dir != null) return dir;
      } catch (_) {}
    }
    return Directory.systemTemp;
  }

  static String _normalize(String v) =>
      v.replaceAll(RegExp(r'^v'), '').split('+').first;

  /// Strict semver-ish comparison on the first three numeric components.
  static bool _isNewer(String latest, String current) {
    List<int> parse(String s) =>
        s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final l = parse(latest);
    final c = parse(current);
    for (int i = 0; i < 3; i++) {
      final lv = i < l.length ? l[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (lv != cv) return lv > cv;
    }
    return false;
  }
}
