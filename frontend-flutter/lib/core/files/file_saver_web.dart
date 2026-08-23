import 'dart:html' as html;
import 'dart:typed_data';

/// Web: trigger a browser download of the decrypted blob.
Future<String> saveBytes(String fileName, Uint8List bytes) async {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = fileName
    ..click();
  html.Url.revokeObjectUrl(url);
  return fileName;
}
