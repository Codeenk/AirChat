/**
 * Published key material: an *opaque, expiring* blob per (uid, kind).
 *
 * Two kinds exist, and the relay understands neither of them:
 *
 *  - `mls`    — an RFC 9420 KeyPackage, so a peer can add this device to an
 *               MLS group.
 *  - `signal` — a libsignal PreKeyBundle, so a peer can run X3DH and open a
 *               Double Ratchet session with this device.
 *
 * The relay stores the client's base64 payload verbatim and hands it back to
 * whoever asks for that uid. It never parses, validates or re-encodes it,
 * because every one of these fields is *public* key material that the holder
 * intends to publish — the point is only to make the fetch asynchronous, not
 * to put the relay in the trust path for it.
 *
 * Two rules from SECURITY.md shape this module:
 *
 *  - "All stored data must have TTLs — no permanent server-side records."
 *    Every row carries `expires_at`, and every read filters on it. A device
 *    that stops publishing falls out of the table by itself, so a uid cannot
 *    be *pre-keyed* indefinitely after its owner is gone.
 *  - "The relay routes, it does not learn." A row is exactly the published
 *    bytes keyed by uid. Nothing here reveals a contact, a conversation or a
 *    group: the relay cannot tell who fetched whom, and it is handed no
 *    roster.
 *
 * `kind` is constrained by the callers, not by the schema, and reads must
 * pass it explicitly — so a lookup cannot accidentally return MLS material
 * where a Signal bundle was expected.
 */

/** How long a published blob survives without being republished. */
export const KEY_PACKAGE_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

/** The kinds of published key material this relay understands. */
export type KeyPackageKind = "mls" | "signal";

const KINDS: readonly KeyPackageKind[] = ["mls", "signal"];

/** Narrows an untrusted value to a known kind. */
export function isKeyPackageKind(value: unknown): value is KeyPackageKind {
  return typeof value === "string" && (KINDS as readonly string[]).includes(value);
}

/**
 * Cap the stored blob so a hostile (or buggy) client cannot use the relay as
 * free bulk storage. A KeyPackage and a PreKeyBundle are both comfortably
 * under 2 KiB; 16 KiB leaves ample headroom for a larger PQXDH bundle and for
 * base64 expansion.
 */
export const MAX_KEY_PACKAGE_BYTES = 16 * 1024;

/** Publish (or republish) one blob, resetting its TTL. */
export async function publishKeyPackage(
  db: D1Database,
  uid: string,
  kind: KeyPackageKind,
  payload: string,
): Promise<void> {
  await db
    .prepare(
      `INSERT OR REPLACE INTO key_packages (uid, kind, payload, created_at, expires_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .bind(uid, kind, payload, Date.now(), Date.now() + KEY_PACKAGE_TTL_MS)
    .run();
}

/** The live blob for (uid, kind), or null when absent or expired. */
export async function getKeyPackage(
  db: D1Database,
  uid: string,
  kind: KeyPackageKind,
): Promise<{ payload: string; expiresAt: number } | null> {
  const row = await db
    .prepare(
      `SELECT payload, expires_at FROM key_packages
       WHERE uid = ? AND kind = ? AND expires_at > ?`,
    )
    .bind(uid, kind, Date.now())
    .first();
  if (!row || typeof row.payload !== "string") return null;
  return { payload: row.payload, expiresAt: row.expires_at as number };
}

/** Drop every blob for a uid (leaving, or rotating identity). */
export async function deleteKeyPackages(
  db: D1Database,
  uid: string,
): Promise<void> {
  await db.prepare(`DELETE FROM key_packages WHERE uid = ?`).bind(uid).run();
}

/**
 * Drop expired rows. D1 has no native TTL, so this runs opportunistically on
 * publish rather than needing a scheduled job.
 */
export async function pruneExpiredKeyPackages(db: D1Database): Promise<void> {
  await db
    .prepare(`DELETE FROM key_packages WHERE expires_at <= ?`)
    .bind(Date.now())
    .run();
}
