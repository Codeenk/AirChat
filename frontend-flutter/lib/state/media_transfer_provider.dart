import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_client.dart';
import '../core/network/media_uploader.dart';

final mediaDownloadProvider =
    FutureProvider.family<Uint8List, Map<String, String>>((ref, params) async {
      return await MediaPipeline.downloadAndDecrypt(
        fileKey: params['fileKey']!,
        secretKeyHex: params['secretKeyHex']!,
        nonceHex: params['nonceHex']!,
        backendUrl: ApiClient.defaultBaseUrl,
      );
    });
