# AirChat — Group Cryptography: current design, limits, and the MLS path

This document exists because of the project's own rule in
`SECURITY_THREAT_MODEL.md` §5.9: **"Security claims must match the threat model.
Overclaiming is a defect."** Group messaging is the one place where AirChat's
claims are currently weaker than a reader would assume, so it is written down
here explicitly instead of being left implied.

## 1. What group messaging does today

Implemented in `lib/core/crypto/sodium_engine.dart` (`encryptGroupMessage` /
`decryptGroupMessage`) and `lib/state/group_provider.dart`.

- A group has **one 32-byte symmetric key**, generated randomly when the group
  is created (`_generateGroupKey`).
- That key is delivered to each member **inside a normal 1:1 E2EE message**
  (`group_invite` / `group_add`), so the relay never sees it.
- Every group message is encrypted with `ChaCha20-Poly1305` under that shared
  key, with a fresh random 12-byte nonce. The ciphertext envelope is `{ct, n}`
  — there is no `epk`, because there is no per-message key agreement.
- Each message additionally carries an **Ed25519 signature** over
  `packetId|text|chatId` from the sender's identity key. Receivers verify it, so
  the relay (or another member) cannot forge a message "from" someone else.
- On a **kick or a voluntary leave**, survivors rotate the key: exactly one
  rotator is elected (the surviving member with the lexicographically smallest
  uid), generates a new key, and re-broadcasts it as a `group_add`. The
  `rekey` bus event drives this, and the rotation runs even with no chat screen
  open.

## 2. What that actually gives you

- The **relay cannot read** group content or recover the group key.
- **Sender authenticity**: a forged group message is rejected.
- **Removal revocation**: once the key is rotated, a removed member's copy no
  longer decrypts new messages.
- **Confidentiality against non-members** who never held the key.

## 3. What it does **not** give you

This is the honest part.

- **No per-message forward secrecy for groups.** Unlike 1:1 chats (which use a
  fresh ephemeral X25519 key per message), every group message under a given
  key is encrypted with *that same key*. Anyone who obtains the current group
  key decrypts **every earlier message still in the local history** that was
  sent under it, not just messages from that point on.
- **No post-compromise security.** There is no Diffie-Hellman ratchet. Once a
  member's device is compromised, the attacker can read group traffic until the
  key is rotated — and rotation only happens on a *membership change*, which may
  never occur.
- **Any current member can read all group history** encrypted under the live
  key, including messages sent before they joined if they are given the same
  key. New members do not automatically receive old ciphertext, but nothing in
  the design *prevents* a member from re-sharing the key with a third party.
- **Group metadata is not hidden from the relay.** See §5 below.

For 1:1 messaging, none of this applies — those chats derive a fresh key per
message.

## 4. Why this was not "just fixed" in v1.6.5

Two hard constraints, both of which are the project's own rules:

1. **`SECURITY.md` says: "Crypto primitives: X25519, ChaCha20-Poly1305, Ed25519
   only. No custom crypto."** A hand-rolled "ratchet" — deriving a message key
   from the group key with a home-made chain — would be exactly the custom,
   unvetted construction that rule forbids. A made-up ratchet is not obviously
   stronger than a shared key, and it would give a false sense of assurance.
2. **Any change to group encryption breaks interoperability with already
   released clients.** There is no in-band negotiation today, so the moment a
   new client encrypts with a derived key, every v1.6.0-and-earlier client in
   that group fails to decrypt. That is a user-visible break, not a refactor.

Doing either of those "quickly" would have made the code *look* more secure
while making it actually less trustworthy. So v1.6.5 corrects the
**documentation** and this file records the real migration.

## 5. Group metadata retained by the relay — found and fixed

While reviewing group secrecy, a separate issue surfaced in the backend worker.
It has since been fixed; this section keeps a record of what the problem was
and what the fix was, because the shape of it is easy to reintroduce.

`backend-worker/src/db/schema.sql` used to define a **permanent** D1 table:

```sql
-- BEFORE
CREATE TABLE IF NOT EXISTS group_memberships (
    group_id     TEXT NOT NULL,
    member_uid   TEXT NOT NULL,
    group_name   TEXT NOT NULL DEFAULT '',   -- written, never read
    created_at   INTEGER NOT NULL,           -- no expiry anywhere
    PRIMARY KEY (group_id, member_uid)
);
```

Two problems:

- It was a **permanent group membership graph** (who is in which group), which
  `SECURITY.md` ("All stored data must have TTLs — no permanent server-side
  records") and `SECURITY_DESIGN.md` §4.1 both say should not exist. Records
  were written with `INSERT OR REPLACE` and only ever read back.
- `group_name` was stored **in plaintext**. Every read in the worker
  (`ConnectionRelay.ts`) selected only `member_uid` or `group_id` — `group_name`
  was written but never read, so it was gratuitous retention of sensitive
  metadata.

### The fix

Membership is now explicitly **transient routing state** — the relay only needs
to know which FCM tokens to wake for a `group_packet`, so a row is exactly
`(group_id, member_uid, expires_at)`:

```sql
-- AFTER
CREATE TABLE IF NOT EXISTS group_memberships (
    group_id   TEXT NOT NULL,
    member_uid TEXT NOT NULL,
    expires_at INTEGER NOT NULL,   -- 30-day TTL, refreshed while in use
    PRIMARY KEY (group_id, member_uid)
);
```

- `group_name` is **gone** from the schema, both insert sites, the
  `/api/group/register` request body, and the `send_group_packet` wire message.
  The relay routes packets, it does not label them; recipients resolve the name
  from the E2EE payload and their own local state.
- `expires_at` gives every row a 30-day TTL. Reads filter on it, so a group no
  client has touched falls out of the table by itself.
- The TTL **slides**: registering a group and sending to it both refresh it, so
  an active group never lapses. `frontend-flutter` also re-registers every
  locally known group once per app launch, so a group that is merely quiet —
  rather than dead — stays routable.
- Expired rows are swept on each register, so no scheduled job is needed.

Shared logic lives in `backend-worker/src/db/membership.ts`; the schema change
for existing databases is
`backend-worker/src/db/migrations/0001_group_memberships_expiry.sql`.

**Deploy ordering matters:** the migration must be applied before the worker
code that reads `expires_at` is deployed, or inserts fail against the old
table.

## 6. Migration plan: MLS (RFC 9420)

**Target:** replace the shared group key with an MLS group so groups get
per-message forward secrecy and post-compromise security. Note that 1:1 does not
have those properties either — it has per-message key freshness, because the
recipient still decrypts with a long-term key that never ratchets
(`SECURITY_DESIGN.md` §3.1). MLS is therefore the target *both* paths should
converge on, not merely a gap to close between groups and 1:1.

**Implementation, not invention.** Use a vetted MLS implementation rather than
writing one. `openmls` (pub.dev) is a Dart binding to **OpenMLS**, the Rust
implementation of RFC 9420 — which satisfies the "no custom crypto" rule in a
way a hand-rolled ratchet cannot.

The work is a protocol project, not a patch. Blockers in dependency order, with
current status:

1. **Ordering — in progress.** MLS advances by *Commits* that must be applied
   in a consistent order per epoch; the relay is unordered and replayable. A
   first, non-MLS piece of this is **done**: group state now carries a monotonic
   `keyVersion` (`groups.key_version`, DB v9), every rotation increments it, and
   a receiver drops any key-carrying control that is not newer than what it
   holds. This closes a real bug that existed independently of MLS —
   replaying an old `group_add`/`group_invite` used to **restore a superseded
   group key**, silently undoing the rotation that revoked a removed member.
   Still open: a *total* order across concurrent membership changes (two writers
   can still pick the same next version) and epoch-divergence handling.
2. **Key packages — likely smaller than first thought.** Each device needs an
   MLS KeyPackage to be added, and joins need Welcome messages. This was
   written down as "a relay + directory change", but reading the code shows the
   existing **encrypted 1:1 channel can carry them**: a KeyPackage request and
   a Welcome are just payloads on a wire the relay already forwards opaquely,
   exactly like today's `group_invite`. The relay needs no new storage for
   them. The real cost is the *round trip* — the current invite flow is
   fire-and-forget, while MLS needs each member's KeyPackage before a group can
   be created.
3. **State storage — in place at the service layer.** MLS group state (ratchet
   tree, epoch secrets) must be persisted encrypted, replacing
   `groups.groupKey`. `openmls` persists its own state in a SQLCipher database
   given a 32-byte key, so this is a key to keep in existing secure storage
   rather than new ratchet tables to design. Done: the 32-byte storage key and
   the MLS signature key pair both live in `flutter_secure_storage` via
   `KeyStore`, and the engine is opened against
   `<documents>/airchat_mls.db`. Not yet done: the per-group mapping from
   `groups.groupKey` to MLS state — legacy groups keep `groupKey` untouched.
4. **Lifecycle mapping.** `group_invite` / `group_add` / `group_kick` become
   Add / Remove commits; `rotateGroupKey` disappears because the ratchet
   replaces it.
5. **Migrating existing groups — decided, and deliberately not started.**
   A shared key cannot be converted into an MLS epoch. Either groups are
   recreated (user-visible), or a `cryptoVersion` is added to group state and
   groups migrate lazily on their next membership change. The chosen rollout is
   **new groups only**: `cryptoVersion` now exists (`groups.crypto_version`, DB
   v11) and defaults to `1` (legacy), so every group in existence reads exactly
   as before and nothing is rewritten behind the user's back. Lazy migration is
   still available later; it is not required for the rollout and is not being
   done speculatively.
6. **Interop / version gating — half done.** The state field exists
   (`GroupCrypto` / `Group.cryptoVersion` / `groups.crypto_version`), and
   `Group.usesMls` is the single decision point. Still open: advertising
   `cryptoVersion` in `group_invite` / `group_add` / `group_kick`, and refusing
   to send MLS material to a peer that has not advertised support. Until that
   exists the transport must not be switched on, because an older client cannot
   read an MLS epoch at all — it would not fail gracefully, it would simply go
   silent.
7. **Verification — partly done, and now load-bearing.** Cross-client interop
   tests, epoch-divergence and out-of-order-commit tests — and, per
   `SECURITY_THREAT_MODEL.md`, an external audit before group secrecy is claimed
   at the same level as 1:1.

   One prerequisite landed: **safety numbers** (`SECURITY_DESIGN.md` §3.4) let
   two users confirm out of band that the keys on their devices are the real
   ones. That matters more for MLS than it did before, because step 2 routes
   KeyPackages and Welcome messages over the pairwise 1:1 channel — so the
   authenticity of that channel is now the thing an Add/Remove commit rests on.
   Without a verified 1:1 channel, a hostile relay can hand a Welcome to an epoch
   it controls. Verification is per contact, so it protects a group exactly as
   far as its members have verified each other.

### Feasibility of the chosen implementation, measured

`openmls` **3.2.0** is now a dependency, and a real Android release build in
this repository's environment was run to test the plan rather than assume it:

- **It builds, for both ABIs we ship.** `libopenmls_frb.so` is produced for
  `arm64-v8a` and `armeabi-v7a` (plus `linux-x86_64`, which is what lets the
  test suite run the real implementation on the host). The Android binaries are
  built by NDK r28c against API 24. Since `flutter build apk --split-per-abi`
  produces both ABIs, the plan is executable as written from a toolchain
  standpoint.
- **It is heavy, measured.** A full `--release --split-per-abi --obfuscate`
  build went from **27.6 MB (armv7) / 33.6 MB (arm64)** at v1.6.5 to **34.6 MB /
  43.6 MB** now — **+7.0 MB and +10.0 MB**, entirely the packaged
  `libopenmls_frb.so` (6.97 MB and 9.96 MB in the APK). The package also pulls
  in `flutter_rust_bridge`, `hooks`, `code_assets`, `native_toolchain_c` and
  `objective_c`, and native libraries are fetched from GitHub Releases at build
  time by Dart build hooks. That is a meaningful increase in build-time and
  supply-chain surface for a project whose `SECURITY.md` is built around minimal
  dependencies — recorded here as a real cost, not waved away.
- **The shipped binary is stripped, but the build warns about an unstripped
  intermediate.** The build prints *"The generated ELF library contains
  unobfuscated DWARF debugging information. To avoid this, use --strip"* three
  times. Checked rather than assumed: the copy inside the release APK is
  `stripped` with zero `.debug` sections, because AGP strips it while packaging,
  so the warning concerns the build-hook cache (20.5 MB arm64 unstripped) and
  not the shipped artifact. The stripped library still contains 237
  `/home/runner/...` strings and Rust stdlib `/rustc/<hash>/library/...` panic
  locations — build-runner paths from the vendor's CI, which is itself part of
  the supply chain and is worth knowing, but nothing sensitive. Debug symbols
  are released separately by the vendor's own build, so they should be treated
  as public by anyone analysing the binary.
- **Its own warning about capabilities is correct and was confirmed in the API
  source**, which is why the narrowing above is mandatory rather than tidy.

**Residual gap from step 1:** an *unversioned* key-carrying control (from a
client built before this change) is still accepted, because rejecting it would
drop legitimate roster updates from older members. The replay hole for that
format narrows automatically as clients upgrade; it is recorded here rather
than papered over.

Until steps 1–7 are done, the accurate statement is the one in README.md:
groups use a rotated shared key, and 1:1 secrecy is stronger than group secrecy.

## 7. What exists in code now (MLS service layer)

`lib/core/crypto/mls_group_service.dart` implements the MLS group operations on
`openmls` **3.2.0**, and `test/mls_group_service_test.dart` exercises them
against the real Rust implementation — each "device" in those tests owns its own
MLS engine over its own in-memory SQLCipher database, and every key package,
welcome, commit and application message on the wire is genuine RFC 9420
material. Fourteen tests pass, covering group creation, adding a member,
exchanging messages with the sender authenticated from the ratchet tree,
refusing a Welcome addressed to a different group, replaying a commit, reaching
agreement on one epoch, **removing a member and confirming they can no longer
decrypt** (the revocation itself), and **a member who joins later being unable to
read earlier traffic** (forward secrecy).

### Configuration, and why each choice is pinned

- **Ciphersuite `0x0003`** — `mls128DhkemX25519Chacha20Poly1305Sha256Ed25519`,
  the RFC 9420 suite assembled from exactly the primitives `SECURITY.md`
  already allowed. The suite actually negotiated by a group is asserted in
  tests against `groupCiphersuite`, not against the constant that was passed in.
- **Capabilities are narrowed explicitly.** This is the sharpest edge in the
  whole integration: left unset, OpenMLS advertises **all thirteen** suites its
  build can execute, and the other ten are *experimental post-quantum suites on
  provisional, non-IANA code points* (`0x004D`, `0x0042`, `0x004E`, `0x004F`,
  `0x0050`, `0x0051`, `0x0052`, `0x0906`, `0x0907`, `0xF042`). A peer choosing
  one would put the group on an unstandardized suite whose code points may be
  renumbered or withdrawn. Both key packages and group creation therefore pin
  `MlsCapabilities.ciphersuites` to `[0x0003]`; key packages go through
  `createKeyPackageWithOptions` because `createKeyPackage` takes no capabilities
  argument at all.
- **No past-epoch or resumption secrets.** `maxPastEpochs` and
  `numberOfResumptionPsks` are set to `0`. Retaining them would let the device
  decrypt its own older traffic, which is the property MLS is here to remove —
  the default is convenient, not secure, so it is overridden.
- **One MLS signature identity per device**, persisted, so a member is the same
  cryptographic principal in every group. The private key is stored only in
  secure storage.
- **Engine calls are serialized** through an internal queue. MLS state is order
  sensitive; two concurrent sends against one group must not interleave.

### Known limitations of this layer, stated plainly

- **It is not wired to the UI or the relay.** Nothing in the app creates an MLS
group yet, no KeyPackage is published or fetched, and no Welcome is delivered.
Group messaging behaves exactly as it did in v1.6.5. This is the transport work
(step 2), and it is what remains before the feature exists for a user.
- **No application-supplied AAD.** `createMessage` accepts an AAD but the only
  read path, `processMessage`, takes none — so a payload sealed with one could
  not be opened, and the parameter would be decorative. Binding to the correct
  group does not rely on it: MLS derives each message key from that group's
  epoch secret, so material sealed for one group fails to decrypt against
  another.
- **The MLS database is not yet tied to the app's lock state.** The engine can
  be closed and reopened, and the storage key is in secure storage, but wiring
  that to app background/lock is not done.
- **No size measurement of the wired-up feature yet**, only of the library:
  the packaging measurement above.
