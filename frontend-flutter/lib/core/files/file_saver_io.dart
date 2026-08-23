import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Native: decrypt into the app's documents directory.
Future<String> saveBytes(String fileName, Uint8List bytes) async {
  final dir = await getApplicationDocumentsDirectory();
  final safeName = fileName.replaceAll(RegExp(r'[^\w.\- ]'), '_');
  final file = File(p.join(dir.path, safeName));
  await file.writeAsBytes(bytes);
  return file.path;
}
