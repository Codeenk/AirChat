-- Sealed sender: address devices by opaque tags instead of uids.
--
-- Both tables deliberately have NO uid column. That is the entire point: there
-- is no row anywhere that joins a tag to a person, so the relay's persisted
-- state cannot be turned into a social graph. A tag is 32 bytes of device-local
-- randomness — meaningless, unguessable, and rotated.
--
-- See SECURITY_SEALED_SENDER.md.
--
-- `device_tags` lets the relay address a device for delivery and for a
-- uid-free "you have mail" push. `group_subscriptions` replaces the old
-- roster upload: each member registers only *its own* (group_tag, member_tag)
-- pair, so the relay never receives a membership list from a third party and
-- never learns which uids are in a group together.
--
-- Both carry `expires_at` per SECURITY.md ("all stored data must have TTLs —
-- no permanent server-side records"). A device refreshes its rows on every
-- connect and on every send, so a live device never lapses while an abandoned
-- one falls out of the table by itself.
CREATE TABLE IF NOT EXISTS device_tags (
    tag        TEXT PRIMARY KEY,
    fcm_token  TEXT,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_device_tags_expiry ON device_tags(expires_at);

CREATE TABLE IF NOT EXISTS group_subscriptions (
    group_tag  TEXT NOT NULL,
    member_tag TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (group_tag, member_tag)
);

CREATE INDEX IF NOT EXISTS idx_group_subscriptions_group ON group_subscriptions(group_tag);
CREATE INDEX IF NOT EXISTS idx_group_subscriptions_member ON group_subscriptions(member_tag);
CREATE INDEX IF NOT EXISTS idx_group_subscriptions_expiry ON group_subscriptions(expires_at);
