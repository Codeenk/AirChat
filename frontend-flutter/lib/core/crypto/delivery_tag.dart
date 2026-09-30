import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../network/websocket_client.dart';

/// A device's sealed-sender **delivery tag**.
///
/// The tag is what a sealed message is addressed to: 32 bytes of device-local
/// randomness, base64url, 43 characters. It is not derived from the uid, the
/// username, or any key, so it cannot be reversed into an identity and cannot be
/// recomputed by the relay. See `SECURITY_SEALED_SENDER.md` §3.
///
/// Everything here is a pure function of the caller's clock and randomness, so
/// the rotation rules are testable without a device, a database, or a relay.
class DeliveryTag {
  /// 256 bits of entropy. Short enough to be a JSON field, long enough that
  /// guessing another device's tag is not a threat model.
  static const int byteLength = 32;

  /// Length of the base64url encoding of [byteLength] bytes without padding.
  static const int encodedLength = 43;

  /// How long one tag is used before the device rotates to a fresh one.
  ///
  /// A tag that never changes is a stable device identifier, which is the thing
  /// this design exists to remove — the relay would be back to holding a durable
  /// handle for each device, just a random-looking one. Rotation is what makes
  /// the relay's `device_tags` table a cache of *current* addresses rather than
  /// a device registry.
  static const Duration rotateAfter = Duration(hours: 24);

  /// How long a superseded tag is still accepted for inbound mail.
  ///
  /// Rotation cannot be atomic across two devices: a peer seals to the tag it
  /// last learned, so for a while after we rotate, mail still arrives addressed
  /// to the previous tag. A grace window means rotation never drops a message.
  static const Duration keepPrevious = Duration(days: 7);

  /// Upper bound on remembered tags, so a device that is rotated rarely (or a
  /// clock that jumps backwards) cannot grow the list without limit.
  static const int maxRemembered = 16;

  /// The relay validates tags with this exact shape, so producing anything else
  /// would be a silently undeliverable address.
  static final RegExp _shape = RegExp('^[A-Za-z0-9_-]{$encodedLength}\$');

  /// Whether [tag] could be a delivery tag this relay would route.
  ///
  /// Used on the *receive* side before trusting a peer-supplied tag, and by the
  /// registry before reusing a stored one.
  static bool isValid(String? tag) {
    if (tag == null || tag.length != encodedLength) return false;
    if (!_shape.hasMatch(tag)) return false;
    try {
      return base64Url.decode('$tag=').length == byteLength;
    } catch (_) {
      return false;
    }
  }

  /// A fresh tag from a cryptographic RNG.
  static String generate({Random? random}) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(byteLength, (_) => rng.nextInt(256));
    return encode(bytes);
  }

  /// base64url without padding — the encoding the relay's validator expects.
  static String encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  /// Whether the newest tag was minted long enough ago to rotate.
  ///
  /// A missing timestamp (first run, or a corrupt record) is treated as "rotate":
  /// minting a tag is cheap and the alternative is reusing one of unknown age.
  static bool rotationDue(DateTime? mintedAt, DateTime now) {
    if (mintedAt == null) return true;
    return now.difference(mintedAt) >= rotateAfter;
  }
}

/// One remembered tag: the tag itself plus when it was minted.
class TagRecord {
  final String tag;
  final DateTime mintedAt;

  const TagRecord({required this.tag, required this.mintedAt});

  Map<String, dynamic> toJson() => {
    't': tag,
    'c': mintedAt.millisecondsSinceEpoch,
  };

  static TagRecord? tryDecode(dynamic raw) {
    try {
      final map = raw as Map;
      final tag = map['t'] as String?;
      final millis = map['c'] as int?;
      if (!DeliveryTag.isValid(tag) || millis == null) return null;
      return TagRecord(
        tag: tag!,
        mintedAt: DateTime.fromMillisecondsSinceEpoch(millis),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Where the tag list lives.
///
/// An interface rather than a direct `FlutterSecureStorage` call because the
/// rotation rules are worth testing on their own, and a test must not need the
/// platform keystore to exercise them.
abstract class DeliveryTagStorage {
  Future<List<TagRecord>> load();
  Future<void> save(List<TagRecord> records);
}

/// Tag list in the platform keystore, alongside the identity key.
///
/// The tag is not secret in the same sense a private key is — but it is the
/// address of this device, and the relay is the adversary. A tag written to
/// plaintext storage that another app on the device could read would let that
/// app claim our mail slot. Errors are swallowed to empty/ignored rather than
/// thrown: a keystore hiccup must degrade this device to the legacy named
/// transport, not crash the app or block sending.
class SecureDeliveryTagStorage implements DeliveryTagStorage {
  static const _key = 'airchat_delivery_tags';
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  const SecureDeliveryTagStorage();

  @override
  Future<List<TagRecord>> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(TagRecord.tryDecode)
          .whereType<TagRecord>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(List<TagRecord> records) async {
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode(records.map((r) => r.toJson()).toList()),
      );
    } catch (_) {}
  }
}

/// In-memory storage for tests.
class InMemoryDeliveryTagStorage implements DeliveryTagStorage {
  List<TagRecord> _records;

  InMemoryDeliveryTagStorage([List<TagRecord>? initial])
    : _records = initial ?? const [];

  @override
  Future<List<TagRecord>> load() async => List<TagRecord>.from(_records);

  @override
  Future<void> save(List<TagRecord> records) async {
    _records = List<TagRecord>.from(records);
  }
}

/// The device's tag list: minting, rotation, grace, and registration.
///
/// Multi-tag rather than a single slot because both rotation and the send path
/// need more than "the current tag":
///
///  * receive — mail can still arrive addressed to a tag we just retired, so
///    every tag inside the grace window stays registered with the relay;
///  * send — a peer keeps using the tag it last learned until it hears from us
///    again, so ours must remain claimable during that window.
///
/// Registration is idempotent and re-runs on every connect, which is what makes
/// a tag claim self-healing if the relay loses the row or another device
/// registered the same tag first (`SECURITY_SEALED_SENDER.md` §4.1).
class DeliveryTagRegistry {
  DeliveryTagRegistry({
    DeliveryTagStorage? storage,
    Random Function()? randomFactory,
    DateTime Function()? clock,
  }) : _storage = storage ?? const SecureDeliveryTagStorage(),
       _randomFactory = randomFactory ?? Random.secure,
       _clock = clock ?? DateTime.now;

  /// App-wide instance. Tests construct their own with memory storage.
  static final DeliveryTagRegistry instance = DeliveryTagRegistry();

  final DeliveryTagStorage _storage;
  final Random Function() _randomFactory;
  final DateTime Function() _clock;

  List<TagRecord>? _cache;

  /// The newest tag, or null when storage is unavailable — in which case the
  /// caller falls back to the legacy named transport. Null is not an error
  /// state: it is "this device cannot be sealed to right now".
  Future<String?> currentTag() async {
    final tags = await _load();
    if (tags.isEmpty) return null;
    return tags.first.tag;
  }

  /// Every tag still inside the grace window, newest first.
  Future<List<String>> activeTags() async =>
      (await _load()).map((r) => r.tag).toList(growable: false);

  /// Returns the current tag, minting one (and pruning expired ones) if this is
  /// the first run or the newest tag is stale.
  Future<String?> ensureTag() async {
    final cutoff = _clock().subtract(DeliveryTag.keepPrevious);
    final existing = await _load();
    final fresh = existing
        .where((r) => r.mintedAt.isAfter(cutoff))
        .take(DeliveryTag.maxRemembered)
        .toList();

    final newest = fresh.isEmpty ? null : fresh.first.mintedAt;
    if (fresh.isEmpty || DeliveryTag.rotationDue(newest, _clock())) {
      final minted = TagRecord(
        tag: DeliveryTag.generate(random: _randomFactory()),
        mintedAt: _clock(),
      );
      final rotated = [
        minted,
        ...fresh,
      ].take(DeliveryTag.maxRemembered).toList();
      await _persist(rotated);
      return minted.tag;
    }

    // Pruned list differs from what was stored → write it back so the record
    // does not grow forever on a device that is only opened occasionally.
    if (fresh.length != existing.length) await _persist(fresh);
    return fresh.first.tag;
  }

  /// Registers every active tag with the relay in one burst.
  ///
  /// [fcmToken] is stored per tag by the relay so a tag we can *receive* on also
  /// wakes this device. Returns the number of tags registered (0 when there is
  /// no usable tag or the socket is not connected yet).
  Future<int> registerOn(SealedTransport client, {String? fcmToken}) async {
    await ensureTag();
    final tags = await activeTags();
    if (tags.isEmpty) return 0;
    for (final tag in tags) {
      client.sealRegister(tag: tag, fcmToken: fcmToken);
    }
    return tags.length;
  }

  Future<List<TagRecord>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    // A storage that throws is treated as "no tags": this device cannot be
    // sealed to, and every send stays on the named transport. The alternative —
    // letting the failure escape — would break sending, which is a much worse
    // outcome than losing a metadata property.
    List<TagRecord> loaded;
    try {
      loaded = await _storage.load();
    } catch (_) {
      loaded = const [];
    }
    // Guard against a corrupt record: a tag the relay would reject is worse
    // than no tag at all, because it looks deliverable from our side.
    final valid = loaded
        .where((r) => DeliveryTag.isValid(r.tag))
        .take(DeliveryTag.maxRemembered)
        .toList(growable: false);
    _cache = valid;
    return valid;
  }

  Future<void> _persist(List<TagRecord> records) async {
    _cache = records;
    try {
      await _storage.save(records);
    } catch (_) {
      // Same reasoning as a failed read: an unwritable keystore costs this
      // device's *next* run the tag, not this one's sending. The in-memory copy
      // above keeps the current session working.
    }
  }

  /// Test seam: drop the in-memory copy so the next read hits storage.
  void resetCacheForTest() => _cache = null;
}
