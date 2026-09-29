/**
 * Group membership: transient *routing* state, not durable history.
 *
 * The relay needs to know which members to wake for a `group_packet`. That is
 * all it needs, so a row is exactly (group_id, member_uid) plus an expiry — no
 * group name, no roster history.
 *
 * Two rules from SECURITY.md shape this module:
 *
 *  - "All stored data must have TTLs — no permanent server-side records."
 *    Rows carry `expires_at` and every read filters on it, so a group the
 *    clients have stopped using falls out of the table by itself.
 *  - Group names are not the relay's business. The row used to carry a
 *    plaintext `group_name` that every insert wrote and no query ever read —
 *    gratuitous retention of sensitive metadata. It is gone.
 *
 * Rows are refreshed (sliding window) whenever a client registers the group or
 * sends to it, so an *active* group never expires while it is being used. A
 * quiet group expires once no client has touched it for GROUP_MEMBERSHIP_TTL_MS.
 */

/** How long routing state survives without being refreshed. */
export const GROUP_MEMBERSHIP_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

/**
 * Upsert the roster for a group, refreshing the expiry for every member.
 * `INSERT OR REPLACE` means a re-register both updates and re-livens the row.
 */
export async function upsertGroupMembership(
  db: D1Database,
  groupId: string,
  memberUids: string[],
): Promise<void> {
  const expiresAt = Date.now() + GROUP_MEMBERSHIP_TTL_MS;
  const stmts = memberUids.map((uid) =>
    db
      .prepare(
        `INSERT OR REPLACE INTO group_memberships (group_id, member_uid, expires_at)
         VALUES (?, ?, ?)`,
      )
      .bind(groupId, uid, expiresAt),
  );
  if (stmts.length > 0) await db.batch(stmts);
}

/**
 * Sliding refresh: an active group is touched by a send, so its routing state
 * is kept alive without the client having to re-register on every packet.
 */
export async function refreshGroupMembership(
  db: D1Database,
  groupId: string,
): Promise<void> {
  await db
    .prepare(
      `UPDATE group_memberships SET expires_at = ?
       WHERE group_id = ? AND expires_at > ?`,
    )
    .bind(Date.now() + GROUP_MEMBERSHIP_TTL_MS, groupId, Date.now())
    .run();
}

/** Live members of a group, or [] if the routing state has expired. */
export async function getGroupMemberUids(
  db: D1Database,
  groupId: string,
): Promise<string[]> {
  const rows = await db
    .prepare(
      `SELECT member_uid FROM group_memberships
       WHERE group_id = ? AND expires_at > ?`,
    )
    .bind(groupId, Date.now())
    .all();
  return rows.results?.map((r: any) => r.member_uid as string) ?? [];
}

/** Live groups a member belongs to, or [] if its routing state has expired. */
export async function getUserGroupIds(
  db: D1Database,
  uid: string,
): Promise<string[]> {
  const rows = await db
    .prepare(
      `SELECT DISTINCT group_id FROM group_memberships
       WHERE member_uid = ? AND expires_at > ?`,
    )
    .bind(uid, Date.now())
    .all();
  return rows.results?.map((r: any) => r.group_id as string) ?? [];
}

/**
 * Drop expired rows. D1 has no native TTL, so this runs opportunistically on
 * register rather than needing a scheduled job.
 */
export async function pruneExpiredMemberships(db: D1Database): Promise<void> {
  await db
    .prepare(`DELETE FROM group_memberships WHERE expires_at <= ?`)
    .bind(Date.now())
    .run();
}
