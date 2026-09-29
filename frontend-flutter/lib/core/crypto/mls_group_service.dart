import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:openmls/openmls.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/group.dart';
import 'key_store.dart';

/// Outcome of processing one inbound MLS message.
class MlsDecryptResult {
  /// Decrypted application payload, when this was an application message.
  final String? plaintext;

  /// True when the message was a Commit and the new epoch has been merged, so
  /// the caller should refresh anything that caches group membership.
  final bool appliedCommit;

  /// Epoch the message belongs to after processing.
  final int epoch;

  /// Identity (uid) of the sender, resolved from the ratchet tree. MLS
  /// authenticates the sender cryptographically, so this is not a claim the
  /// sender chose freely: it is bound to a leaf the group admitted.
  final String? senderUid;

  const MlsDecryptResult({
    this.plaintext,
    this.appliedCommit = false,
    this.epoch = 0,
    this.senderUid,
  });
}

/// Result of admitting members to a group.
class MlsAddResult {
  /// Commit message every existing member must process to advance the epoch.
  final Uint8List commit;

  /// Welcome message each newly added member processes to join.
  final Uint8List welcome;

  const MlsAddResult({required this.commit, required this.welcome});
}

/// The MLS signature key pair, held as raw bytes.
///
/// OpenMLS wants the private and public halves supplied separately and also
/// takes a serialized form of both; keeping our own copy of the two raw keys
/// avoids depending on the encoding of that serialized blob. That blob *does*
/// contain the private key, so it lives in secure storage, never on disk
/// unencrypted and never in a log.
class _MlsSigner {
  final Uint8List bytes;
  final Uint8List publicKey;

  const _MlsSigner({required this.bytes, required this.publicKey});
}

/// RFC 9420 group key agreement, via OpenMLS.
///
/// This wraps a vetted implementation rather than hand-rolling a ratchet:
/// `SECURITY.md` restricts the project to X25519, ChaCha20-Poly1305 and Ed25519
/// with no custom crypto, and a TreeKEM ratchet is precisely the kind of
/// construction that must not be improvised.
///
/// ## Deliberate configuration
///
/// * **Ciphersuite** is pinned to
///   `mls128DhkemX25519Chacha20Poly1305Sha256Ed25519` (API code point 0x0003),
///   the RFC 9420 suite built from exactly the primitives the project already
///   allows, and the one whose AEAD matches the 1:1 path.
/// * **Capabilities are narrowed explicitly.** Left unset, OpenMLS advertises
///   *all thirteen* suites it can execute — ten of them experimental
///   post-quantum suites on provisional, non-IANA code points. A peer picking
///   one would put the group on an unstandardized suite, so both key packages
///   and group creation pin the ciphersuite list to [ciphersuiteCodePoint].
/// * `maxPastEpochs` and `numberOfResumptionPsks` are **0**, so no past-epoch
///   secrets are retained. Retaining them would decrypt old traffic after the
///   fact, which is the forward secrecy MLS is here to provide.
///
/// The version tag that decides whether a group uses this path lives on the
/// model, as [GroupCrypto].
class MlsGroupService {
  MlsGroupService({bool ephemeral = false}) : _ephemeral = ephemeral;

  /// Shared instance for the app. Tests construct their own with
  /// `ephemeral: true`, which keeps MLS state in memory and off platform
  /// channels.
  static final MlsGroupService instance = MlsGroupService();

  final bool _ephemeral;

  MlsEngine? _engine;
  Future<MlsEngine>? _opening;

  _MlsSigner? _signerCache;
  Uint8List? _ephemeralStorageKey;

  /// MLS state is per-group and order sensitive. Every engine call is chained
  /// through this queue so two sends can never interleave against one group's
  /// ratchet.
  Future<void> _queue = Future<void>.value();

  /// The RFC 9420 ciphersuite, documented in [MlsGroupService].
  static const MlsCiphersuite ciphersuite =
      MlsCiphersuite.mls128DhkemX25519Chacha20Poly1305Sha256Ed25519;

  /// IANA code point for [ciphersuite] (RFC 9420 §17.1). Kept as a literal so
  /// the advertised capability list is auditable without reading the enum.
  static const int ciphersuiteCodePoint = 0x0003;

  /// MLS protocol version 1.0.
  static const int protocolVersion = 1;

  // ─── lifecycle ───

  Future<MlsEngine> _ensureEngine() {
    if (_engine == null) {
      final pending = _opening;
      if (pending != null) return pending;
      return _opening = _openEngine();
    }
    return Future.value(_engine);
  }

  Future<MlsEngine> _openEngine() async {
    await Openmls.init();
    final String dbPath;
    final List<int> key;
    if (_ephemeral) {
      dbPath = ':memory:';
      key = _ephemeralStorageKey ??= _randomBytes(32);
    } else {
      dbPath = p.join(
        (await getApplicationDocumentsDirectory()).path,
        'airchat_mls.db',
      );
      key = base64Decode(await KeyStore.getOrCreateMlsStorageKey());
    }
    final engine = await MlsEngine.create(dbPath: dbPath, encryptionKey: key);
    _engine = engine;
    return engine;
  }

  /// Close the MLS engine, wiping its key from memory and releasing the DB.
  /// State persists on disk (native), so the next call reopens it.
  Future<void> close() async {
    final engine = _engine;
    _engine = null;
    _opening = null;
    if (engine != null && !engine.isClosed()) {
      await engine.close();
    }
  }

  // ─── signer ───

  /// MLS signature key, reused across sessions so a member keeps one
  /// cryptographic identity in every group it belongs to.
  Future<_MlsSigner> _signer() async {
    final cached = _signerCache;
    if (cached != null) return cached;

    final Uint8List privateKey;
    final Uint8List publicKey;

    if (_ephemeral) {
      final pair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
      privateKey = pair.privateKey();
      publicKey = pair.publicKey();
    } else {
      final storedPrivate = await KeyStore.getMlsSignerPrivateKey();
      final storedPublic = await KeyStore.getMlsSignerPublicKey();
      if (storedPrivate != null && storedPublic != null) {
        privateKey = base64Decode(storedPrivate);
        publicKey = base64Decode(storedPublic);
      } else {
        final pair = MlsSignatureKeyPair.generate(ciphersuite: ciphersuite);
        privateKey = pair.privateKey();
        publicKey = pair.publicKey();
        await KeyStore.saveMlsSigner(
          privateKeyBase64: base64Encode(privateKey),
          publicKeyBase64: base64Encode(publicKey),
        );
      }
    }

    return _signerCache = _MlsSigner(
      bytes: serializeSigner(
        ciphersuite: ciphersuite,
        privateKey: privateKey,
        publicKey: publicKey,
      ),
      publicKey: publicKey,
    );
  }

  /// Narrowed capabilities, described in [MlsGroupService].
  static MlsCapabilities _capabilities() => MlsCapabilities(
    versions: Uint16List.fromList([protocolVersion]),
    ciphersuites: Uint16List.fromList([ciphersuiteCodePoint]),
    extensions: Uint16List(0),
    proposals: Uint16List(0),
    credentials: Uint16List(0),
  );

  /// Group config with past-epoch retention switched off.
  static MlsGroupConfig _config() {
    final defaults = MlsGroupConfig.defaultConfig(ciphersuite: ciphersuite);
    return MlsGroupConfig(
      ciphersuite: ciphersuite,
      wireFormatPolicy: defaults.wireFormatPolicy,
      // Carry the ratchet tree in the GroupInfo so a joiner needs only the
      // Welcome, with no separate tree fetch to authenticate.
      useRatchetTreeExtension: true,
      maxPastEpochs: 0,
      paddingSize: defaults.paddingSize,
      senderRatchetMaxOutOfOrder: defaults.senderRatchetMaxOutOfOrder,
      senderRatchetMaxForwardDistance: defaults.senderRatchetMaxForwardDistance,
      numberOfResumptionPsks: 0,
    );
  }

  static Uint8List _id(String groupId) => utf8.encode(groupId);

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(n, (_) => rng.nextInt(256), growable: false),
    );
  }

  /// Runs [op] with the engine, serialized against every other MLS operation.
  Future<T> _locked<T>(Future<T> Function(MlsEngine engine) op) async {
    final previous = _queue;
    final gate = Completer<void>();
    _queue = gate.future;
    await previous;
    try {
      return await op(await _ensureEngine());
    } finally {
      gate.complete();
    }
  }

  // ─── key packages ───

  /// Build the KeyPackage a peer needs in order to add this device to a group.
  ///
  /// Returned bytes are safe to hand to the relay: they are a public offer, not
  /// key material.
  ///
  /// Uses `createKeyPackageWithOptions` rather than `createKeyPackage` because
  /// the latter takes no capabilities argument and therefore advertises every
  /// suite the build supports.
  Future<Uint8List> generateKeyPackage({required String selfUid}) {
    return _locked((engine) async {
      final signer = await _signer();
      final result = await engine.createKeyPackageWithOptions(
        ciphersuite: ciphersuite,
        signerBytes: signer.bytes,
        credentialIdentity: utf8.encode(selfUid),
        signerPublicKey: signer.publicKey,
        options: KeyPackageOptions(
          capabilities: _capabilities(),
          lastResort: false,
          // Default lifetime (84 days). A stale package is refused by the
          // adder rather than silently admitted, which is the safe direction.
        ),
      );
      return result.keyPackageBytes;
    });
  }

  // ─── group lifecycle ───

  /// Create an MLS group. [groupId] is the app's group id, used verbatim as the
  /// MLS group identifier so the two can never disagree.
  Future<void> createGroup({required String groupId, required String selfUid}) {
    return _locked((engine) async {
      final signer = await _signer();
      await engine.createGroup(
        config: _config(),
        signerBytes: signer.bytes,
        credentialIdentity: utf8.encode(selfUid),
        signerPublicKey: signer.publicKey,
        groupId: _id(groupId),
      );
    });
  }

  /// Admit members by their KeyPackages. Advances the epoch, so the returned
  /// Commit must reach every existing member and the Welcome every new one.
  Future<MlsAddResult> addMembers({
    required String groupId,
    required List<Uint8List> keyPackages,
  }) {
    return _locked((engine) async {
      final result = await engine.addMembers(
        groupIdBytes: _id(groupId),
        signerBytes: (await _signer()).bytes,
        keyPackagesBytes: keyPackages,
      );
      return MlsAddResult(commit: result.commit, welcome: result.welcome);
    });
  }

  /// Remove members by uid. Removing a member advances the epoch, so the
  /// returned Commit is what actually revokes their access: before it they can
  /// still read, after it they cannot derive the new keys.
  Future<Uint8List> removeMembers({
    required String groupId,
    required List<String> uids,
  }) {
    return _locked((engine) async {
      final ids = _id(groupId);
      final indices = <int>[];
      final wanted = uids.toSet();
      for (final member in await engine.groupMembers(groupIdBytes: ids)) {
        if (wanted.contains(_identityOf(member))) indices.add(member.index);
      }
      if (indices.isEmpty) {
        throw StateError('No matching MLS member to remove');
      }
      final result = await engine.removeMembers(
        groupIdBytes: ids,
        signerBytes: (await _signer()).bytes,
        memberIndices: Uint32List.fromList(indices),
      );
      return result.commit;
    });
  }

  /// Join a group from a Welcome produced by [addMembers].
  ///
  /// [expectedGroupId] is checked against the welcome's own group id, so a
  /// relay cannot splice one group's welcome into another. The ciphersuite is
  /// checked too: a welcome for an experimental suite must not silently pull
  /// this device onto one.
  Future<void> joinFromWelcome({
    required String expectedGroupId,
    required Uint8List welcome,
  }) {
    return _locked((engine) async {
      final config = _config();
      final inspected = await engine.inspectWelcome(
        config: config,
        welcomeBytes: welcome,
      );
      if (utf8.decode(inspected.groupId) != expectedGroupId) {
        throw StateError('Welcome is for a different group');
      }
      if (inspected.ciphersuite != ciphersuite) {
        throw StateError('Welcome uses an unexpected ciphersuite');
      }
      await engine.joinGroupFromWelcome(
        config: config,
        welcomeBytes: welcome,
        signerBytes: (await _signer()).bytes,
      );
    });
  }

  /// Members currently in the group, as uids, resolved from ratchet-tree
  /// credentials.
  Future<List<String>> members(String groupId) {
    return _locked((engine) async {
      final result = <String>[];
      for (final member in await engine.groupMembers(
        groupIdBytes: _id(groupId),
      )) {
        final uid = _identityOf(member);
        if (uid != null) result.add(uid);
      }
      return result;
    });
  }

  /// Current MLS epoch. Advances by one on every commit (add/remove/update).
  Future<int> epoch(String groupId) {
    return _locked(
      (engine) async =>
          (await engine.groupEpoch(groupIdBytes: _id(groupId))).toInt(),
    );
  }

  /// The ciphersuite the group actually negotiated.
  ///
  /// Exposed so the pinned suite is asserted against real group state rather
  /// than against the constant we hope was used.
  Future<MlsCiphersuite> negotiatedCiphersuite(String groupId) {
    return _locked(
      (engine) async => engine.groupCiphersuite(groupIdBytes: _id(groupId)),
    );
  }

  /// Whether this device holds MLS state for [groupId].
  Future<bool> hasGroup(String groupId) async {
    try {
      await epoch(groupId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Drop MLS state for a group (leaving it, or deleting a local group).
  Future<void> deleteGroup(String groupId) {
    return _locked((engine) => engine.deleteGroup(groupIdBytes: _id(groupId)));
  }

  // ─── messaging ───

  /// Encrypt an application message for the group's current epoch.
  ///
  /// No application-supplied AAD is used. `processMessage` — the only read path
  /// — takes no AAD argument, so a payload sealed with one could not be opened;
  /// the parameter would be decorative. Binding to the right group does not
  /// depend on it: MLS derives each message's key from that group's epoch
  /// secret, so a message sealed for one group simply fails to decrypt against
  /// another, and `decrypt` is told which group it is operating on.
  Future<Uint8List> encrypt({
    required String groupId,
    required Uint8List plaintext,
  }) {
    return _locked((engine) async {
      final result = await engine.createMessage(
        groupIdBytes: _id(groupId),
        signerBytes: (await _signer()).bytes,
        message: plaintext,
      );
      return result.ciphertext;
    });
  }

  /// Process any inbound MLS message: application data, a proposal, or a
  /// membership commit.
  ///
  /// A staged commit is merged immediately, which is what advances the epoch
  /// and revokes a removed member.
  Future<MlsDecryptResult> decrypt({
    required String groupId,
    required Uint8List message,
  }) {
    return _locked((engine) async {
      final ids = _id(groupId);
      final processed = await engine.processMessage(
        groupIdBytes: ids,
        messageBytes: message,
      );

      final epoch = processed.epoch.toInt();
      String? senderUid;
      final index = processed.senderIndex;
      if (index != null) {
        final member = await engine.groupMemberAt(
          groupIdBytes: ids,
          leafIndex: index,
        );
        if (member != null) senderUid = _identityOf(member);
      }

      var appliedCommit = false;
      if (processed.messageType == ProcessedMessageType.stagedCommit) {
        await engine.mergePendingCommit(groupIdBytes: ids);
        appliedCommit = true;
      }

      final bytes = processed.applicationMessage;
      return MlsDecryptResult(
        plaintext: bytes == null ? null : utf8.decode(bytes),
        appliedCommit: appliedCommit,
        epoch: epoch,
        senderUid: senderUid,
      );
    });
  }

  /// uid from a ratchet-tree credential, or null for a non-basic credential.
  static String? _identityOf(MlsMemberInfo member) {
    try {
      final cred = MlsCredential.deserialize(bytes: member.credential);
      return utf8.decode(cred.identity());
    } catch (_) {
      return null;
    }
  }
}
