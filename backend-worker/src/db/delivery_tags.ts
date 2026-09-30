/**
 * Sealed-sender addressing: opaque device tags and self-subscribed group
 * membership.
 *
 * Both tables are keyed by random tags, never by uid. See
 * SECURITY_SEALED_SENDER.md for why that is the whole design: there is no row
 * anywhere that joins a tag to a person, so the relay's *persisted* state
 * cannot be assembled into a social graph.
 *
 * Rules from SECURITY.md that shape this module:
 *
 *  - "All stored data must have TTLs — no permanent server-side records."
 *    Every row carries `expires_at` and every read filters on it. A device
 *    refreshes its row on every connect and every send, so a live device never
 *    lapses while an abandoned one falls out by itself.
 *  - Minimal retention: a device row is exactly (tag, fcm_token, expiry) and a
 *    subscription is exactly (group_tag, member_tag, expiry).
 */

/** How long a tag registration or subscription survives without a refresh. */
export const TAG_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

/**
 * A tag is 32 bytes of base64url — 43 characters, unpadded. Rejecting anything
 * else keeps a client from parking arbitrary text (or an oversized blob) in a
 * table the relay reads on the hot path.
 */
const TAG_RE = /^[A-Za-z0-9_-]{43}$/;

export function isValidTag(tag: unknown): tag is string {
  if (typeof tag !== "string" || !TAG_RE.test(tag)) return false;
  try {
    // Confirm it really decodes to 32 bytes rather than merely looking right.
    const b64 = tag.replace(/-/g, "+").replace(/_/g, "/") + "=";
    return atob(b64).length === 32;
  } catch {
    return false;
  }
}

/**
 * Register (or refresh) a device tag. Called on every connect, so a live device
 * keeps a rolling 30-day window.
 *
 * The FCM token is stored with the tag and *without* a uid, which is what lets
 * the relay wake the device without knowing who it is.
 */
export async function registerDeviceTag(
  db: D1Database,
  tag: string,
  fcmToken: string | null,
): Promise<void> {
  const now = Date.now();
  await db
    .prepare(
      `INSERT INTO device_tags (tag, fcm_token, created_at, expires_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(tag) DO UPDATE SET
         fcm_token  = COALESCE(excluded.fcm_token, device_tags.fcm_token),
         expires_at = excluded.expires_at`,
    )
    .bind(tag, fcmToken, now, now + TAG_TTL_MS)
    .run();
}

/**
 * Is this tag live? Used to reject sealed packets addressed to something the
 * relay has never seen, so a client cannot spray traffic at invented tags.
 *
 * The caller must return a *generic* failure for both "unknown tag" and
 * "expired tag" — a distinguishable answer would let a client enumerate or
 * probe tags.
 */
export async function isLiveTag(db: D1Database, tag: string): Promise<boolean> {
  const row = await db
    .prepare(`SELECT 1 AS ok FROM device_tags WHERE tag = ? AND expires_at > ?`)
    .bind(tag, Date.now())
    .first();
  return !!row;
}

/** The push token for a tag, or null when the device registered none. */
export async function getTagFcmToken(
  db: D1Database,
  tag: string,
): Promise<string | null> {
  const row: { fcm_token: string | null } | null = await db
    .prepare(`SELECT fcm_token FROM device_tags WHERE tag = ? AND expires_at > ?`)
    .bind(tag, Date.now())
    .first();
  return row?.fcm_token ?? null;
}

/**
 * Self-subscribe a device to a group. The member sends only *its own* tag, so
 * the relay never receives a roster and never learns which uids share a group.
 */
export async function subscribeToGroup(
  db: D1Database,
  groupTag: string,
  memberTag: string,
): Promise<void> {
  const now = Date.now();
  await db
    .prepare(
      `INSERT INTO group_subscriptions (group_tag, member_tag, created_at, expires_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(group_tag, member_tag) DO UPDATE SET expires_at = excluded.expires_at`,
    )
    .bind(groupTag, memberTag, now, now + TAG_TTL_MS)
    .run();
}

/** Live member tags for a group, or [] if the group's routing state lapsed. */
export async function getGroupMemberTags(
  db: D1Database,
  groupTag: string,
): Promise<string[]> {
  const rows = await db
    .prepare(
      `SELECT member_tag FROM group_subscriptions
       WHERE group_tag = ? AND expires_at > ?`,
    )
    .bind(groupTag, Date.now())
    .all();
  return rows.results?.map((r: any) => r.member_tag as string) ?? [];
}

/** Live group tags a member is subscribed to, or [] if they have lapsed. */
export async function getMemberGroupTags(
  db: D1Database,
  memberTag: string,
): Promise<string[]> {
  const rows = await db
    .prepare(
      `SELECT DISTINCT group_tag FROM group_subscriptions
       WHERE member_tag = ? AND expires_at > ?`,
    )
    .bind(memberTag, Date.now())
    .all();
  return rows.results?.map((r: any) => r.group_tag as string) ?? [];
}

/**
 * Sliding refresh: a send touches the group, so its routing state is kept alive
 * without every member having to re-subscribe on each packet.
 */
export async function refreshGroupSubscriptions(
  db: D1Database,
  groupTag: string,
): Promise<void> {
  await db
    .prepare(
      `UPDATE group_subscriptions SET expires_at = ?
       WHERE group_tag = ? AND expires_at > ?`,
    )
    .bind(Date.now() + TAG_TTL_MS, groupTag, Date.now())
    .run();
}

/**
 * Drop expired rows. D1 has no native TTL, so this runs opportunistically on
 * registration rather than needing a scheduled job.
 */
export async function pruneExpiredTags(db: D1Database): Promise<void> {
  const now = Date.now();
  await db.prepare(`DELETE FROM device_tags WHERE expires_at <= ?`).bind(now).run();
  await db
    .prepare(`DELETE FROM group_subscriptions WHERE expires_at <= ?`)
    .bind(now)
    .run();
}
