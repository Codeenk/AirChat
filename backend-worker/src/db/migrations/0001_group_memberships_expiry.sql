-- group_memberships: drop the gratuitous plaintext group name, add a TTL.
--
-- Before: (group_id, member_uid, group_name, created_at), no expiry. A
-- permanent, plaintext group-name record that no query ever read — it violated
-- SECURITY.md's "All stored data must have TTLs — no permanent server-side
-- records" and retained sensitive metadata for no reason.
--
-- After: (group_id, member_uid, expires_at). Routing state only.
--
-- SQLite cannot portably DROP a column that participates in a table created by
-- older engines, so the table is rebuilt. Existing rows are preserved and given
-- a fresh 30-day window (rather than being dated from their original
-- `created_at`, which would silently drop groups that are still in use).

CREATE TABLE IF NOT EXISTS group_memberships_new (
    group_id   TEXT NOT NULL,
    member_uid TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (group_id, member_uid)
);

INSERT OR IGNORE INTO group_memberships_new (group_id, member_uid, expires_at)
    SELECT group_id,
           member_uid,
           CAST(strftime('%s', 'now') AS INTEGER) * 1000 + 2592000000
    FROM group_memberships;

DROP TABLE group_memberships;

ALTER TABLE group_memberships_new RENAME TO group_memberships;

CREATE INDEX IF NOT EXISTS idx_group_memberships_member ON group_memberships(member_uid);
CREATE INDEX IF NOT EXISTS idx_group_memberships_group ON group_memberships(group_id);
CREATE INDEX IF NOT EXISTS idx_group_memberships_expiry ON group_memberships(expires_at);
