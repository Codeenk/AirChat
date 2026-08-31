class MediaAttachment {
  final String fileKey;
  final String secretKeyHex;
  final String nonceHex;
  final String type; // 'image', 'voice', 'document'
  final String fileName;

  MediaAttachment({
    required this.fileKey,
    required this.secretKeyHex,
    required this.nonceHex,
    required this.type,
    required this.fileName,
  });

  Map<String, dynamic> toJson() => {
    'fileKey': fileKey,
    'secretKeyHex': secretKeyHex,
    'nonceHex': nonceHex,
    'type': type,
    'fileName': fileName,
  };

  factory MediaAttachment.fromJson(Map<String, dynamic> json) =>
      MediaAttachment(
        fileKey: json['fileKey'] ?? '',
        secretKeyHex: json['secretKeyHex'] ?? '',
        nonceHex: json['nonceHex'] ?? '',
        type: json['type'] ?? 'image',
        fileName: json['fileName'] ?? 'attachment',
      );
}
