# AirChat v1.7.0 — key verification, and the MLS foundation

Two things in this release: users can now **verify who they are talking to**,
and the group-cryptography work moved from a plan to running, tested code. One
of them changes what you see in the app; the other does not yet.

## 1. Safety numbers / key verification (new, user-visible)

Encryption cannot tell you *whose* keys you are encrypting to. The relay hands
out public keys, so a malicious or compromised relay can substitute its own and
read along — and nothing in the app would have noticed, because there was no way
to check. That was the single largest hole in the "a remote attacker cannot read
this" claim.

Each chat now has a **security code**: a 60-digit number derived from *both*
parties' keys. If both phones show the same digits, no one substituted keys.
Compare by reading aloud, copying, or scanning the other device's QR code.

The details that make it real rather than decorative:

- **Symmetric** — both sides compute identical digits.
- **Covers the Ed25519 signing key, not only the X25519 identity key**, so a
  match also rules out a swapped signing key.
- **Every field in the transcript is length-prefixed**, so bytes cannot be
  shifted between fields to forge a match.
- **Verification stores the keys as they were when you compared them.** If
  either changes later, the chat shows a red *"Security code changed"* banner
  and a warning icon. A changed key can never silently inherit a green check.
- **Scanning a code that disagrees with the relay offers to adopt the scanned
  key** — the out-of-band code outranks the directory.

Until you compare a code, the app does not claim the contact is verified.

## 2. Relay metadata leak fixed (needs a deploy — see below)

`group_memberships` was permanent, had no delete path, and stored the **group
name in plaintext that every insert wrote and no query ever read**. It violated
the project's own "all stored data must have TTLs" rule for no benefit.

It is now explicitly transient *routing* state, `(group_id, member_uid,
expires_at)`:

- `group_name` is gone from the schema, both insert sites, the register request
  body, and the wire message. The relay routes packets; it does not label them.
- Every row has a **30-day sliding TTL**, refreshed on register and on send, so
  an active group never lapses. Reads filter on it, so no cleanup job is needed.
  The app re-registers its groups once per launch, so a quiet group stays
  routable.

**This requires a worker deploy to take effect**, and the migration must land
first:

```bash
cd backend-worker
npx wrangler d1 migrations apply airchat-identity --remote
npx wrangler deploy
```

Not deploying does not break anything: the currently deployed worker treats the
removed `groupName` field as optional, so a client running this release keeps
working against the older relay. Deploying is what removes the retention.

## 3. Replay fix for group key rotation

The relay is unordered and replayable, so an old `group_add` / `group_invite`
carrying a group key could arrive *after* a newer one and **restore a superseded
key** — silently undoing the rotation that revoked a removed member. Group state
now carries a monotonic `keyVersion` (DB v9), incremented on every rotation, and
a receiver drops any key-carrying control that is not newer than what it holds.

## 4. MLS group crypto — implemented and tested, **not yet wired**

`openmls` 3.2.0 (Dart bindings to OpenMLS, the Rust RFC 9420 implementation) is
now a dependency, and `lib/core/crypto/mls_group_service.dart` implements the
group operations: create, add members, remove members, join from Welcome,
encrypt/decrypt, membership and epoch queries.

**Be clear about what this is and is not.** It is verified code with 14 tests
that run against the *real* Rust implementation — each test device owning its own
MLS engine, using genuine RFC 9420 key packages, welcomes, commits and
application messages. Those tests confirm real properties, not just that the code
ran:

- a **removed member cannot decrypt** messages sent after the removal;
- a member who **joins later cannot read earlier traffic**;
- a **replayed commit is rejected** without moving the epoch;
- two devices reach the **same epoch** from the same commit;
- a Welcome addressed to a **different group is refused**.

But **no group in the app uses it yet**. No KeyPackage is published, no Welcome
is delivered, group creation still uses the shared key, and every existing group
reads as `cryptoVersion = 1` exactly as before. The reason is deliberate: switching
the wire format before version gating exists would not fail gracefully for a peer
on a released build — it would go silent. So group messaging behaves exactly as
it did in v1.6.5.

Configuration is pinned, not defaulted:

- ciphersuite **`0x0003`** — `mls128DhkemX25519Chacha20Poly1305Sha256Ed25519`,
  assembled from exactly the primitives `SECURITY.md` allows;
- capabilities **narrowed explicitly**. Left unset, OpenMLS advertises all
  thirteen suites it can execute, ten of which are *experimental post-quantum
  suites on provisional, non-IANA code points*. A peer selecting one would put
  the group on an unstandardized suite;
- `maxPastEpochs` and `numberOfResumptionPsks` set to **0**, because retaining
  past-epoch secrets would let a device decrypt its own older traffic — the
  property MLS exists to remove.

### Cost, stated plainly

The native library adds **+7.0 MB (armv7) and +10.0 MB (arm64)** to the APKs for
a feature that is not yet reachable in the app: 27.6 MB → **34.6 MB** and
33.6 MB → **43.6 MB**. That is a real cost paid ahead of the benefit, and it is
recorded in `SECURITY_GROUP_CRYPTO.md` §7 rather than glossed over.

## 5. Group secrecy is still not 1:1 secrecy

Groups still run on a rotated shared key. This release makes the migration
*foundation* real; it does not make groups forward-secret. `SECURITY_DESIGN.md`
§3.3 and `SECURITY_GROUP_CRYPTO.md` §6–§7 say exactly where each blocker stands.
Both remain open, along with a 1:1 ratchet, notification preview control, voice
calls, iOS, and the independent audit.

## Verification

- `dart format` — 0 files changed.
- `flutter analyze` — **0 errors, 0 warnings** (73 pre-existing infos).
- `flutter test` — **77/77** (was 63; +14 MLS).
- `flutter build apk --release --split-per-abi --obfuscate` — clean, all three
  ABIs. The packaged `libopenmls_frb.so` was checked and is **stripped** (zero
  `.debug` sections), despite build warnings about an unstripped *intermediate*.
- `backend-worker`: `npm run typecheck` clean.
