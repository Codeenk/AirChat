import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateInfo {
  final String latestTag;
  final String htmlUrl;
  final String body;
  final String downloadUrl;

  const UpdateInfo({
    required this.latestTag,
    required this.htmlUrl,
    required this.body,
    required this.downloadUrl,
  });

  bool get isNewerThanCurrent => true;
}

class UpdateChecker {
  static const String _apiUrl =
      'https://api.github.com/repos/Codeenk/AirChat/releases/latest';

  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = _normalize(info.version);

      final res = await http
          .get(Uri.parse(_apiUrl), headers: {'Accept': 'application/vnd.github.v3+json'})
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
      if (assets != null && assets.isNotEmpty) {
        for (final a in assets) {
          final name = (a as Map<String, dynamic>)['name'] as String? ?? '';
          if (name.contains('arm64')) {
            downloadUrl = a['browser_download_url'] as String? ?? htmlUrl;
            break;
          }
        }
        downloadUrl = (assets.first as Map<String, dynamic>)['browser_download_url']
                as String? ??
            htmlUrl;
      }

      return UpdateInfo(
        latestTag: tag,
        htmlUrl: htmlUrl,
        body: body,
        downloadUrl: downloadUrl,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> openRelease(UpdateInfo info) async {
    final uri = Uri.parse(info.htmlUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  static Future<void> openDownload(UpdateInfo info) async {
    final uri = Uri.parse(info.downloadUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  static String _normalize(String v) => v.replaceAll(RegExp(r'^v'), '').split('+').first;

  static bool _isNewer(String latest, String current) {
    List<int> parse(String s) =>
        s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final l = parse(latest);
    final c = parse(current);
    for (int i = 0; i < 3; i++) {
      final lv = i < l.length ? l[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (lv > cv) return true;
      if (lv < cv) return false;
    }
    return latest != current && latest.contains(RegExp(r'beta|alpha|rc')) == false;
  }
}
