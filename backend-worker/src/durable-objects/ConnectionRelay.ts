export interface EphemeralPacket {
  id: string;
  senderUid: string;
  recipientUid: string;
  payload: string;
  timestamp: number;
}

interface SocketLease {
  ws: WebSocket;
  lastSeen: number;
}

/**
 * A sealed packet as it exists at rest.
 *
 * Note what is NOT here: no `senderUid` and no `recipientUid`. The recipient is
 * only in the storage *key*, as an opaque tag, because the relay has to know
 * where to deliver. The sender is nowhere, because sealed delivery never needed
 * to know it. This is the difference between the legacy `EphemeralPacket` above
 * (which is an edge) and this record (which is not).
 */
export interface SealedPacket {
  pid: string;
  body: string;
  /** The sender's own tag, quoted so a status/receipt has a return path. */
  reply: string;
  /** Opaque 16-byte sender pseudonym. Lets the recipient attribute in O(1). */
  hint: string | null;
  ts: number;
}

import {
  sendSilentWake,
  sendDeliveryFailedWake,
  sendGroupWake,
  sendSealedWake,
} from "../utils/fcm";
import { verifyEd25519Signature } from "../utils/crypto-verify";
import * as membership from "../db/membership";
import * as deliveryTags from "../db/delivery_tags";

const TTL_MS = 24 * 60 * 60 * 1000; // 24h ephemeral cache — the only server storage
const LEASE_MS = 90 * 1000; // socket lease: ping every 25s refreshes; >90s = dead wire
const MAX_BATCH = 128; // storage.delete / list batch safety

// ─── Sealed sender ───
// Storage prefixes are distinct from the legacy `msg:` / `grp:` prefixes so a
// sealed tag can never collide with a uid in the same namespace.
const SEALED_MSG_PREFIX = "sm:";
const SEALED_GROUP_PREFIX = "sg:";

/** Largest accepted sealed body, base64 chars (~96 KiB raw). Media is uploaded
 * out of band, so a message body has no business being larger. */
const MAX_SEALED_BODY = 128 * 1024;

/**
 * Mixing window. A sealed packet bound for an online device is held briefly and
 * delivered with its batch in shuffled order, so neither arrival *time* nor
 * arrival *order* maps onto delivery time or order. That is what makes the
 * relay's own real-time view much less useful for correlating two sockets, and
 * it is why the window is random rather than fixed.
 *
 * Kept small on purpose: this is a messenger, and the latency budget for
 * hiding timing is seconds at most, not minutes.
 */
const MIX_MIN_MS = 400;
const MIX_MAX_MS = 1600;

export class ConnectionRelay {
  private state: DurableObjectState;
  private env: any;
  // Lease-based socket registry: a wire exists only while the client keeps
  // pinging. Dead wires (no close event, e.g. process killed) are evicted
  // once their lease expires — messages are never "relayed" into them.
  private sockets: Map<string, SocketLease> = new Map();

  // ─── Sealed sender state ───
  // Devices addressed by opaque tag. Kept separate from `sockets` (which is
  // uid-keyed) so the two addressing modes can never be confused.
  private sealedSockets: Map<string, SocketLease> = new Map();
  // Which tags a given socket has registered. A *set* rather than a single tag
  // because a tag rotates: the device keeps its previous tag registered for a
  // grace period so mail already addressed to it still lands instead of being
  // lost. Membership is what scopes an ack to the caller's own queue, so
  // acknowledging grants no power over anyone else's mail.
  private wsTags: Map<WebSocket, Set<string>> = new Map();
  // Packets waiting in the mixing window.
  private sealedBatch: Array<{ to: string; packetId: string }> = [];
  private batchTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(state: DurableObjectState, env?: any) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/ws" || url.pathname === "/tunnel") {
      const upgradeHeader = request.headers.get("Upgrade");
      if (!upgradeHeader || upgradeHeader.toLowerCase() !== "websocket") {
        return new Response("Expected Upgrade: websocket", { status: 426 });
      }

      // `uid` is optional. A sealed-mode socket addresses devices by opaque tag
      // and has no identity to prove, so it connects without one; it is then
      // confined to the tag-scoped sealed actions, because `hasIdentity` below
      // makes uid auth impossible for it. Legacy uid addressing still requires
      // the parameter.
      const uid = url.searchParams.get("uid") ?? "";

      const webSocketPair = new WebSocketPair();
      const [client, server] = Object.values(webSocketPair);

      await this.handleSession(server, uid);
      return new Response(null, { status: 101, webSocket: client });
    }

    return new Response("Not found", { status: 404 });
  }

  private async handleSession(ws: WebSocket, uid: string): Promise<void> {
    ws.accept();

    // ─── WS AUTH CHALLENGE ───
    // The socket must prove ownership of uid by signing nonce+uid with the
    // Ed25519 signing key registered in D1. Until authed: no flush, no
    // send, no ack/delete. This kills impersonation (anyone opening
    // /tunnel?uid=victim) — previously a full queue-drain + delete primitive.
    const nonceBytes = new Uint8Array(16);
    crypto.getRandomValues(nonceBytes);
    const nonce = Array.from(nonceBytes)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    let authed = false;
    // A socket that connected without ?uid has no identity to prove, so it can
    // never satisfy the challenge and can never reach any uid-addressed action.
    const hasIdentity = uid.length > 0;
    try {
      ws.send(JSON.stringify({ type: "auth_challenge", nonce }));
    } catch { /* socket already dead */ }
    // A sealed-mode socket is legitimately unauthenticated: it holds only an
    // opaque tag, which confers no privilege. So the "you must auth" timer only
    // applies to sockets that have done neither.
    const authTimer = setTimeout(() => {
      if (!authed && !(this.wsTags.get(ws)?.size ?? 0)) {
        try { ws.close(4401, "auth required"); } catch { /* ignore */ }
      }
    }, 10000);

    ws.addEventListener("message", async (event) => {
      try {
        const data = JSON.parse(event.data as string);

        if (data.action === "auth") {
          const ok = hasIdentity && (await this.verifySocketAuth(uid, nonce, data.signature));
          if (ok) {
            authed = true;
            clearTimeout(authTimer);
            try {
              ws.send(JSON.stringify({ type: "auth_ok" }));
            } catch { /* ignore */ }
            // Replace any stale wire for this uid (old socket without close event).
            const stale = this.sockets.get(uid);
            if (stale && stale.ws !== ws) {
              try { stale.ws.close(4000, "replaced"); } catch { /* already dead */ }
            }
            this.sockets.set(uid, { ws, lastSeen: Date.now() });
            // Authenticated: now safe to flush.
            await this.flushEphemeralQueue(ws, uid);
            await this.flushGroupInboxes(ws, uid);
          } else {
            try { ws.close(4401, "auth failed"); } catch { /* ignore */ }
          }
          return;
        }

        // ─── HEARTBEAT ───
        // Deliberately ahead of the auth gate: a sealed socket is legitimately
        // unauthenticated, so gating its ping on `authed` would mean its lease
        // never refreshed and the wire was evicted after 90s.
        if (data.action === "ping") {
          // Only refresh the uid lease if this socket actually authenticated as
          // it. Without the `authed` check, anyone could open `?uid=victim` and
          // keep a stranger's wire lease alive by pinging it.
          if (authed) {
            const lease = this.sockets.get(uid);
            if (lease && lease.ws === ws) lease.lastSeen = Date.now();
          }
          const myTags = this.wsTags.get(ws);
          if (myTags !== undefined) {
            for (const t of myTags) {
              const sealedLease = this.sealedSockets.get(t);
              if (sealedLease) sealedLease.lastSeen = Date.now();
            }
          }
          ws.send(JSON.stringify({ type: "pong", timestamp: Date.now() }));
          return;
        }

        // ─── SEALED SENDER ───
        // These run *before* the auth gate on purpose. A sealed socket carries
        // no uid, so it can never satisfy uid auth — and it does not need to:
        // every operation below is scoped to the caller's own tag.
        if (data.action === "seal_register") {
          await this.handleSealRegister(ws, data);
          return;
        }
        if (data.action === "seal") {
          await this.handleSealSend(ws, data);
          return;
        }
        if (data.action === "seal_ack" || data.action === "seal_receipt") {
          await this.handleSealReceipt(ws, data, data.action === "seal_ack");
          return;
        }
        if (data.action === "seal_group") {
          await this.handleSealGroupSend(ws, data);
          return;
        }
        if (data.action === "group_subscribe") {
          await this.handleGroupSubscribe(ws, data);
          return;
        }

        // Everything below requires an authenticated wire.
        if (!authed) return;

        if (data.action === "send_packet") {
          const { recipientUid, encryptedPayload, packetId } = data;
          const targetLease = this.getLiveLease(recipientUid);

          if (targetLease) {
            // Direct real-time WebSocket delivery (the wire)
            targetLease.ws.send(JSON.stringify({
              type: "direct_message",
              senderUid: uid,
              packetId,
              payload: encryptedPayload,
              timestamp: Date.now()
            }));

            // Immediate ACK to sender
            ws.send(JSON.stringify({ type: "packet_status", packetId, status: "relayed" }));
          } else {
            // Recipient offline -> 24h ephemeral cache (the only server storage)
            await this.enqueueEphemeralPacket({
              id: packetId,
              senderUid: uid,
              recipientUid,
              payload: encryptedPayload,
              timestamp: Date.now()
            });

            // Dispatch silent FCM wake-up notification
            console.log(`[relay] enqueue ${packetId} for ${recipientUid} (sender ${uid})`);
            await this.dispatchSilentPushWake(recipientUid, uid);

            ws.send(JSON.stringify({ type: "packet_status", packetId, status: "queued_ephemeral" }));
          }
        }

        // ─── GROUP PACKET: one encrypted payload → stored once, woken to all members ───
        if (data.action === "send_group_packet") {
          const { groupId, encryptedPayload, packetId, senderName } = data;
          if (!groupId || !packetId) {
            ws.send(JSON.stringify({ type: "error", message: "Missing groupId or packetId" }));
            return;
          }

          // Store ONE copy in group inbox (keyed by groupId, not by memberUid).
          // No group name: the relay routes this, it does not label it.
          const groupKey = `grp:${groupId}:${packetId}`;
          await this.state.storage.put(groupKey, {
            id: packetId,
            senderUid: uid,
            groupId,
            payload: encryptedPayload,
            timestamp: Date.now(),
          } as EphemeralPacket & { groupId: string });

          // A send touches the group, so refresh the roster's expiry before
          // reading it — an active group's routing state never lapses.
          if (this.env?.DB) await membership.refreshGroupMembership(this.env.DB, groupId);

          // Look up all group members from D1 and wake each offline member
          const members = await this.getGroupMembers(groupId);
          let wokenCount = 0;
          for (const memberUid of members) {
            if (memberUid === uid) continue; // don't wake the sender
            const memberLease = this.getLiveLease(memberUid);
            if (memberLease) {
              // Member is online — push directly to their wire
              memberLease.ws.send(JSON.stringify({
                type: "group_packet",
                senderUid: uid,
                senderName: senderName || "",
                groupId,
                packetId,
                payload: encryptedPayload,
                timestamp: Date.now(),
              }));
            } else {
              // Member offline — opaque FCM wake (names resolved on-device)
              await this.dispatchGroupPushWake(memberUid, uid, groupId);
              wokenCount++;
            }
          }

          console.log(`[relay] group_packet ${packetId} for ${groupId}: ${members.length} members, ${wokenCount} wakes`);
          ws.send(JSON.stringify({ type: "packet_status", packetId, status: "relayed" }));
          return;
        }

        // ─── REGISTER GROUP: store membership for wake routing ───
        if (data.action === "register_group") {
          const { groupId, memberUids } = data;
          if (!groupId || !Array.isArray(memberUids)) return;
          if (!this.env?.DB) return;

          await membership.upsertGroupMembership(this.env.DB, groupId, memberUids);
          console.log(`[relay] registered group ${groupId}: ${memberUids.length} members`);
          return;
        }

        if (data.action === "ack") {
          const { packetId, senderUid } = data;
          await this.state.storage.delete(`msg:${uid}:${packetId}`);

          const senderLease = this.getLiveLease(senderUid);
          if (senderLease) {
            senderLease.ws.send(JSON.stringify({ type: "delivery_receipt", packetId, status: "delivered" }));
          }
        }

        if (data.action === "ack_group") {
          const { packetId, groupId } = data;
          if (groupId && packetId) {
            await this.state.storage.delete(`grp:${groupId}:${packetId}`);
          }
          return;
        }

        if (data.action === "read_receipt") {
          const { packetId, senderUid } = data;
          if (!packetId || !senderUid) return;

          // Best-effort: notify the original sender that their message was read.
          const senderLease = this.getLiveLease(senderUid);
          if (senderLease) {
            senderLease.ws.send(JSON.stringify({ type: "read_receipt", packetId }));
          }
        }
      } catch (err) {
        ws.send(JSON.stringify({ type: "error", message: "Malformed packet" }));
      }
    });

    ws.addEventListener("close", () => {
      const lease = this.sockets.get(uid);
      if (lease && lease.ws === ws) {
        this.sockets.delete(uid);
      }
      const tags = this.wsTags.get(ws);
      if (tags !== undefined) {
        this.wsTags.delete(ws);
        for (const tag of tags) {
          const sealedLease = this.sealedSockets.get(tag);
          if (sealedLease && sealedLease.ws === ws) {
            this.sealedSockets.delete(tag);
          }
        }
      }
    });
  }

  /// Verifies Ed25519(nonce + uid) against the signing key in D1.
  private async verifySocketAuth(
    uid: string,
    nonce: string,
    signature: unknown
  ): Promise<boolean> {
    try {
      if (typeof signature !== "string" || signature.length === 0) return false;
      const row: { signing_public_key: string | null } | null =
        await this.env.DB.prepare(
          "SELECT signing_public_key FROM users WHERE uid = ?"
        ).bind(uid).first();
      const pubKey = row?.signing_public_key;
      if (!pubKey) {
        console.log(`[relay] auth: no signing key for ${uid}`);
        return false;
      }
      const ok = await verifyEd25519Signature(pubKey, signature, nonce + uid);
      console.log(`[relay] auth ${ok ? "ok" : "FAILED"} for ${uid}`);
      return ok;
    } catch {
      return false;
    }
  }

  /// A wire is live only if the socket is open AND its lease is fresh.
  private getLiveLease(uid: string): SocketLease | null {
    const lease = this.sockets.get(uid);
    if (!lease) return null;
    if (lease.ws.readyState !== WebSocket.READY_STATE_OPEN) {
      this.sockets.delete(uid);
      return null;
    }
    if (Date.now() - lease.lastSeen > LEASE_MS) {
      // Dead wire: process died without a close event. Evict + close.
      try { lease.ws.close(4001, "lease expired"); } catch { /* ignore */ }
      this.sockets.delete(uid);
      return null;
    }
    return lease;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SEALED SENDER
  //
  // The goal is narrow and absolute: deliver a message without ever learning
  // who sent it. So none of the methods below take, derive, or persist a sender
  // uid — not in a variable, not in a log line, not in a storage key. The only
  // identifiers involved are opaque tags the relay cannot reverse.
  //
  // See SECURITY_SEALED_SENDER.md.
  // ═══════════════════════════════════════════════════════════════════════════

  /** A sealed wire is live only if the socket is open AND its lease is fresh. */
  private getLiveSealedLease(tag: string): SocketLease | null {
    const lease = this.sealedSockets.get(tag);
    if (!lease) return null;
    if (lease.ws.readyState !== WebSocket.READY_STATE_OPEN) {
      this.sealedSockets.delete(tag);
      return null;
    }
    if (Date.now() - lease.lastSeen > LEASE_MS) {
      try { lease.ws.close(4001, "lease expired"); } catch { /* ignore */ }
      this.sealedSockets.delete(tag);
      return null;
    }
    return lease;
  }

  /**
   * Bind this socket to an opaque tag and register the tag for delivery + wake.
   *
   * No uid is read or written. The tag is unguessable device randomness, so
   * registering one grants nothing an attacker could leverage: it only means
   * "deliver what is addressed to this tag on this socket". Re-registering
   * always wins, which is how a device reclaims its tag after any collision.
   */
  private async handleSealRegister(ws: WebSocket, data: any): Promise<void> {
    const tag = data?.tag;
    if (!deliveryTags.isValidTag(tag)) {
      try { ws.send(JSON.stringify({ type: "error", message: "Invalid tag" })); } catch { /* ignore */ }
      return;
    }

    // A newer wire replaces a stale one for the same tag (old socket died
    // without a close event, or the app was reinstalled).
    const stale = this.sealedSockets.get(tag);
    if (stale && stale.ws !== ws) {
      try { stale.ws.close(4000, "replaced"); } catch { /* already dead */ }
    }
    let mine = this.wsTags.get(ws);
    if (!mine) {
      mine = new Set<string>();
      this.wsTags.set(ws, mine);
    }
    mine.add(tag);
    this.sealedSockets.set(tag, { ws, lastSeen: Date.now() });

    const fcm =
      typeof data?.fcm === "string" && data.fcm.length > 0 ? data.fcm : null;
    if (this.env?.DB) {
      try {
        await deliveryTags.registerDeviceTag(this.env.DB, tag, fcm);
      } catch { /* a DB hiccup must not stop the socket from working */ }
    }

    try { ws.send(JSON.stringify({ type: "seal_registered" })); } catch { /* ignore */ }
    await this.flushSealedQueue(ws, tag);
    await this.flushSealedGroupInboxes(ws, tag);
  }

  /**
   * A sealed message: `to` is a recipient tag, `reply` is the sender's own tag.
   *
   * The relay never learns who either party is. The `reply` tag exists purely so
   * a delivery status has somewhere to go; using a uid there would reintroduce
   * the leak, and using a per-peer pseudonym would let the relay accumulate a
   * stable pseudonymous edge. A device's own tag leaks neither.
   */
  private async handleSealSend(ws: WebSocket, data: any): Promise<void> {
    const to = data?.to;
    const reply = data?.reply;
    const packetId = data?.packetId;
    const body = data?.body;
    const hint = typeof data?.hint === "string" && data.hint.length > 0 ? data.hint : null;

    if (!deliveryTags.isValidTag(to) || !deliveryTags.isValidTag(reply)) {
      this.sealStatus(ws, packetId, "invalid_request");
      return;
    }
    if (typeof packetId !== "string" || packetId.length === 0 || packetId.length > 64) {
      this.sealStatus(ws, null, "invalid_request");
      return;
    }
    if (typeof body !== "string" || body.length === 0 || body.length > MAX_SEALED_BODY) {
      this.sealStatus(ws, packetId, "invalid_request");
      return;
    }

    // Anti-abuse only: the submitting socket must be a known device (a
    // registered tag) or a uid-authenticated legacy client. Which of the two is
    // deliberately not recorded, and is never stored with the packet.
    if (!(this.wsTags.get(ws)?.size ?? 0) && !this.isAuthedSocket(ws)) {
      this.sealStatus(ws, packetId, "not_registered");
      return;
    }

    if (!this.env?.DB) {
      this.sealStatus(ws, packetId, "unavailable");
      return;
    }

    // Unknown/expired tag: answer generically. Distinguishing "never existed"
    // from "expired" would give a client an oracle for probing tags.
    const live = await deliveryTags.isLiveTag(this.env.DB, to).catch(() => false);
    if (!live) {
      this.sealStatus(ws, packetId, "unknown_recipient");
      return;
    }

    const key = `${SEALED_MSG_PREFIX}${to}:${packetId}`;
    await this.state.storage.put<SealedPacket>(key, {
      pid: packetId,
      body,
      reply,
      hint,
      ts: Date.now(),
    });
    await this.armExpiryAlarm();

    if (this.getLiveSealedLease(to)) {
      // Recipient is online: hold the packet in the mixing window instead of
      // firing it off immediately, so submission time is not delivery time.
      this.sealedBatch.push({ to, packetId });
      this.scheduleSealedFlush();
      this.sealStatus(ws, packetId, "relayed");
    } else {
      await this.dispatchSealedWake(to);
      this.sealStatus(ws, packetId, "queued_ephemeral");
    }
  }

  /**
   * Consume a sealed packet and, if the packet quoted a reply tag, pass the
   * status along. The recipient states only which opaque packet it took — never
   * who sent it — so this is not an edge assertion.
   *
   * Deletion is scoped to the caller's own registered tag, so acknowledging
   * grants no power over anyone else's queue and needs no identity to authorise.
   */
  private async handleSealReceipt(
    ws: WebSocket,
    data: any,
    isAck: boolean,
  ): Promise<void> {
    // `tag` is the caller's own tag, and it must be one this socket actually
    // registered — that check is the entire authorisation, and it needs no
    // identity. A caller can therefore only ever consume mail addressed to it.
    const tag = data?.tag;
    const packetId = data?.packetId;
    const reply = data?.reply;
    if (typeof packetId !== "string" || packetId.length === 0) return;
    if (typeof tag !== "string" || !this.ownsTag(ws, tag)) return;

    await this.state.storage.delete(`${SEALED_MSG_PREFIX}${tag}:${packetId}`);

    if (!deliveryTags.isValidTag(reply)) return;
    // Never signal a receipt back to a socket that is not currently live: there
    // is no uid to fall back to for an offline sender, and the sender's client
    // treats a missing status as "queued", which is the honest answer.
    const lease = this.getLiveSealedLease(reply);
    if (!lease) return;
    try {
      lease.ws.send(
        JSON.stringify(
          isAck
            ? { type: "seal_status", packetId, status: "delivered" }
            : { type: "seal_read", packetId },
        ),
      );
    } catch { /* best effort */ }
  }

  /**
   * A sealed group packet: stored once under the group's opaque tag, with **no
   * sender field at all**, and fanned out to member tags.
   *
   * The sender is resolved by each member from the group's ratchet tree, so the
   * relay does not need to know it — which is why the stored record can drop
   * `senderUid` entirely rather than merely hiding it.
   */
  private async handleSealGroupSend(ws: WebSocket, data: any): Promise<void> {
    // The sender states its *own* tag (a tag is not an identity, so naming it
    // leaks nothing the relay did not already see) and we check it is one this
    // socket registered. That is how the sender is skipped from its own fan-out
    // without the relay ever knowing who the sender is.
    const tag = data?.from;
    const groupTag = data?.groupTag;
    const packetId = data?.packetId;
    const body = data?.body;

    if (!deliveryTags.isValidTag(groupTag)) {
      this.sealStatus(ws, packetId, "invalid_request");
      return;
    }
    if (typeof packetId !== "string" || packetId.length === 0 || packetId.length > 64) {
      this.sealStatus(ws, null, "invalid_request");
      return;
    }
    if (typeof body !== "string" || body.length === 0 || body.length > MAX_SEALED_BODY) {
      this.sealStatus(ws, packetId, "invalid_request");
      return;
    }
    if (typeof tag !== "string" || !this.ownsTag(ws, tag)) {
      this.sealStatus(ws, packetId, "not_registered");
      return;
    }

    const key = `${SEALED_GROUP_PREFIX}${groupTag}:${packetId}`;
    await this.state.storage.put(key, {
      pid: packetId,
      body,
      ts: Date.now(),
    });
    await this.armExpiryAlarm();

    if (this.env?.DB) {
      await deliveryTags.refreshGroupSubscriptions(this.env.DB, groupTag).catch(() => {});
    }

    // Wake every subscriber that is not the sender. Compare by tag, so the
    // sender is skipped without the relay knowing (or recording) who it is.
    const members = this.env?.DB
      ? await deliveryTags.getGroupMemberTags(this.env.DB, groupTag).catch(() => [])
      : [];
    const offline: string[] = [];
    for (const memberTag of members) {
      if (memberTag === tag) continue; // do not wake the sender
      if (this.getLiveSealedLease(memberTag)) continue; // online: will flush
      offline.push(memberTag);
    }
    for (const memberTag of offline) {
      await this.dispatchSealedWake(memberTag);
    }

    this.sealStatus(ws, packetId, "relayed");
  }

  /**
   * Self-subscribe to a group. The member sends only *its own* tag — never a
   * roster — so the relay cannot assemble a "who is in which group" graph.
   */
  private async handleGroupSubscribe(ws: WebSocket, data: any): Promise<void> {
    const tag = data?.memberTag;
    const groupTag = data?.groupTag;
    if (!this.env?.DB) return;
    if (typeof tag !== "string" || !this.ownsTag(ws, tag)) return;
    if (typeof groupTag !== "string" || groupTag.length === 0 || groupTag.length > 128) return;
    await deliveryTags
      .subscribeToGroup(this.env.DB, groupTag, tag)
      .catch(() => { /* routing state, not correctness */ });
  }

  /** Deliver everything queued for a tag, deleting only on a successful send. */
  private async flushSealedQueue(ws: WebSocket, tag: string): Promise<void> {
    const queued = await this.state.storage.list<SealedPacket>({
      prefix: `${SEALED_MSG_PREFIX}${tag}:`,
    });
    if (queued.size === 0) return;

    for (const [key, packet] of queued) {
      try {
        ws.send(
          JSON.stringify({
            type: "sealed_message",
            // `to` is the recipient's own tag, echoed back so it can ack the
            // exact queue slot it consumed. It is the recipient's own address,
            // so it reveals nothing.
            to: tag,
            packetId: packet.pid,
            body: packet.body,
            hint: packet.hint,
            timestamp: packet.ts,
          }),
        );
        await this.state.storage.delete(key);
      } catch {
        return; // socket died mid-flush: the rest stays queued
      }
    }
  }

  /** Deliver every queued sealed group packet for the groups this tag is in. */
  private async flushSealedGroupInboxes(ws: WebSocket, tag: string): Promise<void> {
    if (!this.env?.DB) return;
    const groupTags = await deliveryTags
      .getMemberGroupTags(this.env.DB, tag)
      .catch(() => []);
    if (groupTags.length === 0) return;

    for (const groupTag of groupTags) {
      const queued = await this.state.storage.list<any>({
        prefix: `${SEALED_GROUP_PREFIX}${groupTag}:`,
      });
      for (const [key, packet] of queued) {
        try {
          ws.send(
            JSON.stringify({
              type: "sealed_group_message",
              groupTag,
              to: tag,
              packetId: packet.pid,
              body: packet.body,
              timestamp: packet.ts,
            }),
          );
          await this.state.storage.delete(key);
        } catch {
          return;
        }
      }
    }
  }

  /** Hold and re-order a delivery so timing carries less signal (see §8). */
  private scheduleSealedFlush(): void {
    if (this.batchTimer) return; // a window is already open; this packet joins it
    const window = MIX_MIN_MS + Math.floor(Math.random() * (MIX_MAX_MS - MIX_MIN_MS));
    this.batchTimer = setTimeout(() => {
      this.batchTimer = null;
      this.flushSealedBatch().catch(() => { /* storage-backed, so nothing is lost */ });
    }, window);
  }

  private async flushSealedBatch(): Promise<void> {
    const batch = this.sealedBatch;
    this.sealedBatch = [];
    if (batch.length === 0) return;

    // Shuffle in place: arrival order must not determine delivery order. N is
    // small (one window of traffic), so Fisher-Yates over the batch is enough.
    for (let i = batch.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      const tmp = batch[i];
      batch[i] = batch[j];
      batch[j] = tmp;
    }

    for (const item of batch) {
      const lease = this.getLiveSealedLease(item.to);
      if (!lease) continue; // recipient went away; it stays queued for next connect
      const key = `${SEALED_MSG_PREFIX}${item.to}:${item.packetId}`;
      const packet = await this.state.storage.get<SealedPacket>(key);
      if (!packet) continue; // already flushed or acked
      try {
        lease.ws.send(
          JSON.stringify({
            type: "sealed_message",
            to: item.to,
            packetId: packet.pid,
            body: packet.body,
            hint: packet.hint,
            timestamp: packet.ts,
          }),
        );
        await this.state.storage.delete(key);
      } catch { /* leave it queued rather than lose it */ }
    }
  }

  /**
   * "You have mail" — the wake carries nothing else. No sender, no group, no
   * packet id, so Google sees a device receive a notification and nothing
   * about who sent it or what conversation it belongs to.
   */
  private async dispatchSealedWake(tag: string): Promise<void> {
    if (!this.env?.DB) return;
    try {
      const fcmToken = await deliveryTags.getTagFcmToken(this.env.DB, tag);
      if (!fcmToken) return;
      await sendSealedWake(this.env, fcmToken);
    } catch { /* push is best-effort; the queue still delivers on next connect */ }
  }

  private sealStatus(ws: WebSocket, packetId: unknown, status: string): void {
    try {
      ws.send(JSON.stringify({ type: "seal_status", packetId, status }));
    } catch { /* socket already gone */ }
  }

  /**
   * Is this socket authenticated as *some* uid? Used only as a coarse anti-abuse
   * gate for sealed submission. The answer is never recorded alongside a packet
   * — that is the whole point.
   */
  private isAuthedSocket(ws: WebSocket): boolean {
    for (const lease of this.sockets.values()) {
      if (lease.ws === ws) return true;
    }
    return false;
  }

  /** Did *this* socket register the given tag? */
  private ownsTag(ws: WebSocket, tag: string): boolean {
    return this.wsTags.get(ws)?.has(tag) ?? false;
  }

  /** Start the 24h sweep if one is not already pending. */
  private async armExpiryAlarm(): Promise<void> {
    const current = await this.state.storage.getAlarm();
    if (!current) {
      await this.state.storage.setAlarm(Date.now() + TTL_MS);
    }
  }

  private async enqueueEphemeralPacket(packet: EphemeralPacket): Promise<void> {
    const key = `msg:${packet.recipientUid}:${packet.id}`;
    await this.state.storage.put(key, packet);

    const currentAlarm = await this.state.storage.getAlarm();
    if (!currentAlarm) {
      await this.state.storage.setAlarm(Date.now() + TTL_MS);
    }
  }

  private async flushEphemeralQueue(ws: WebSocket, uid: string): Promise<void> {
    const prefix = `msg:${uid}:`;
    const queuedMap = await this.state.storage.list<EphemeralPacket>({ prefix });
    console.log(`[relay] flush uid=${uid} queued=${queuedMap.size}`);

    for (const [key, msg] of queuedMap) {
      ws.send(JSON.stringify({
        type: "direct_message",
        senderUid: msg.senderUid,
        packetId: msg.id,
        payload: msg.payload,
        timestamp: msg.timestamp
      }));
      await this.state.storage.delete(key);
    }
  }

  // ─── GROUP INBOX: flush all group packets for this user ───
  private async flushGroupInboxes(ws: WebSocket, uid: string): Promise<void> {
    // Get all groups this user belongs to
    const groupIds = await this.getUserGroupIds(uid);
    if (groupIds.length === 0) return;

    let totalFlushed = 0;
    for (const groupId of groupIds) {
      const prefix = `grp:${groupId}:`;
      const queuedMap = await this.state.storage.list<any>({ prefix });
      for (const [key, msg] of queuedMap) {
        ws.send(JSON.stringify({
          type: "group_packet",
          senderUid: msg.senderUid,
          senderName: "",
          groupId: msg.groupId || groupId,
          packetId: msg.id,
          payload: msg.payload,
          timestamp: msg.timestamp,
        }));
        await this.state.storage.delete(key);
        totalFlushed++;
      }
    }
    if (totalFlushed > 0) {
      console.log(`[relay] flushed ${totalFlushed} group packets for ${uid}`);
    }
  }

  // ─── GROUP MEMBERSHIP: transient routing state in D1 (see db/membership.ts) ───
  // Never throws: a missing/erroring DB degrades to "no known groups", which
  // is what an unregistered client sees anyway.
  private async getGroupMembers(groupId: string): Promise<string[]> {
    if (!this.env?.DB) return [];
    try {
      return await membership.getGroupMemberUids(this.env.DB, groupId);
    } catch {
      return [];
    }
  }

  private async getUserGroupIds(uid: string): Promise<string[]> {
    if (!this.env?.DB) return [];
    try {
      return await membership.getUserGroupIds(this.env.DB, uid);
    } catch {
      return [];
    }
  }

  // 24-hour expiry alarm: the ephemeral cache is the ONLY server storage, so
  // expired messages are destroyed — and every sender is honestly notified
  // that their message was not delivered.
  async alarm(): Promise<void> {
    const now = Date.now();
    const cutoff = now - TTL_MS;
    const allMessages = await this.state.storage.list<EphemeralPacket>({ prefix: "msg:" });

    // senderUid -> failed packetIds (for the notification payload)
    const expiredBySender = new Map<string, { recipientUid: string; packetIds: string[] }>();
    const toDelete: string[] = [];

    for (const [key, packet] of allMessages) {
      if (packet.timestamp < cutoff) {
        toDelete.push(key);
        const entry = expiredBySender.get(packet.senderUid) ?? {
          recipientUid: packet.recipientUid,
          packetIds: [],
        };
        entry.packetIds.push(packet.id);
        expiredBySender.set(packet.senderUid, entry);
      }
    }

    // Also expire group packets
    const allGroupPackets = await this.state.storage.list<any>({ prefix: "grp:" });
    for (const [key, packet] of allGroupPackets) {
      if (packet.timestamp < cutoff) {
        toDelete.push(key);
      }
    }

    // ─── Sealed packets ───
    // Same 24h lifetime. The one thing we cannot do here is *push* an expiry
    // notice to an offline sender: we hold only their opaque reply tag, and
    // turning that into a push would require the identity link this whole
    // design removes. A live sender still gets the event; an offline one is
    // covered by the client's own send timeout, which is the honest trade.
    const expiredSealedByReply = new Map<string, string[]>();
    for (const prefix of [SEALED_MSG_PREFIX, SEALED_GROUP_PREFIX]) {
      const expired = await this.state.storage.list<any>({ prefix });
      for (const [key, packet] of expired) {
        if (packet.ts < cutoff) {
          toDelete.push(key);
          const reply = packet.reply;
          if (typeof reply === "string" && deliveryTags.isValidTag(reply)) {
            const list = expiredSealedByReply.get(reply) ?? [];
            list.push(packet.pid);
            expiredSealedByReply.set(reply, list);
          }
        }
      }
    }

    if (toDelete.length > 0) {
      await this.state.storage.delete(toDelete);
    }

    // Notify each sender: live wire gets a WS event, offline gets a push.
    for (const [senderUid, info] of expiredBySender) {
      await this.notifySenderOfExpiry(senderUid, info.recipientUid, info.packetIds);
    }

    // Sealed senders are told only if currently connected, addressed by tag.
    for (const [replyTag, packetIds] of expiredSealedByReply) {
      const lease = this.getLiveSealedLease(replyTag);
      if (!lease) continue;
      try {
        lease.ws.send(JSON.stringify({ type: "seal_status", packetIds, status: "expired" }));
      } catch { /* best effort */ }
    }

    // TTL sweep for the tag registries as well, so no row outlives its window.
    if (this.env?.DB) {
      await deliveryTags.pruneExpiredTags(this.env.DB).catch(() => {});
    }

    // Reschedule alarm only if messages remain
    const remaining = await this.state.storage.list({ prefix: "msg:", limit: 1 });
    const remainingGroup = await this.state.storage.list({ prefix: "grp:", limit: 1 });
    const remainingSealed = await this.state.storage.list({ prefix: SEALED_MSG_PREFIX, limit: 1 });
    const remainingSealedGroup = await this.state.storage.list({ prefix: SEALED_GROUP_PREFIX, limit: 1 });
    if (
      remaining.size > 0 ||
      remainingGroup.size > 0 ||
      remainingSealed.size > 0 ||
      remainingSealedGroup.size > 0
    ) {
      await this.state.storage.setAlarm(now + TTL_MS);
    }
  }

  private async notifySenderOfExpiry(
    senderUid: string,
    recipientUid: string,
    packetIds: string[]
  ): Promise<void> {
    try {
      const senderLease = this.getLiveLease(senderUid);
      if (senderLease) {
        senderLease.ws.send(JSON.stringify({
          type: "delivery_failed",
          packetIds,
          recipientUid,
          reason: "expired",
        }));
        console.log(`[relay] expiry notified (ws) sender=${senderUid} packets=${packetIds.length}`);
        return;
      }

      // Sender offline: wake push so their app can mark the messages failed.
      const row: { fcm_token: string | null } | null = await this.env.DB.prepare(
        "SELECT fcm_token FROM users WHERE uid = ?"
      ).bind(senderUid).first();

      if (!row?.fcm_token) return;
      const ok = await sendDeliveryFailedWake(this.env, row.fcm_token, packetIds, recipientUid);
      console.log(`[relay] expiry notified (push=${ok}) sender=${senderUid} packets=${packetIds.length}`);
    } catch (e) {
      console.log(`[relay] expiry notify failed sender=${senderUid}: ${e}`);
    }
  }

  // FCM Silent Data-only Push Wake Notification (opaque: uid only)
  private async dispatchSilentPushWake(recipientUid: string, senderUid: string): Promise<void> {
    try {
      const row: { fcm_token: string | null } | null =
        await this.env.DB.prepare(
          "SELECT fcm_token FROM users WHERE uid = ?"
        ).bind(recipientUid).first();

      const fcmToken = row?.fcm_token;
      if (!fcmToken) {
        console.log(`[relay] wake skip: no fcm token for ${recipientUid}`);
        return;
      }

      const ok = await sendSilentWake(this.env, fcmToken, senderUid);
      console.log(`[relay] wake sent=${ok} to ${recipientUid}`);
    } catch {
      // Ignore push dispatch errors if FCM is unconfigured
    }
  }

  // FCM push wake for group messages — opaque groupId only.
  private async dispatchGroupPushWake(
    recipientUid: string,
    senderUid: string,
    groupId: string,
  ): Promise<void> {
    try {
      const row: { fcm_token: string | null } | null = await this.env.DB.prepare(
        "SELECT fcm_token FROM users WHERE uid = ?"
      ).bind(recipientUid).first();

      const fcmToken = row?.fcm_token;
      if (!fcmToken) {
        console.log(`[relay] group wake skip: no fcm token for ${recipientUid}`);
        return;
      }

      const ok = await sendGroupWake(this.env, fcmToken, senderUid, groupId);
      console.log(`[relay] group wake sent=${ok} to ${recipientUid} for group ${groupId}`);
    } catch {
      // Ignore push dispatch errors
    }
  }
}
