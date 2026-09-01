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

import { sendSilentWake, sendDeliveryFailedWake, sendGroupWake } from "../utils/fcm";

const TTL_MS = 24 * 60 * 60 * 1000; // 24h ephemeral cache — the only server storage
const LEASE_MS = 90 * 1000; // socket lease: ping every 25s refreshes; >90s = dead wire
const MAX_BATCH = 128; // storage.delete / list batch safety

export class ConnectionRelay {
  private state: DurableObjectState;
  private env: any;
  // Lease-based socket registry: a wire exists only while the client keeps
  // pinging. Dead wires (no close event, e.g. process killed) are evicted
  // once their lease expires — messages are never "relayed" into them.
  private sockets: Map<string, SocketLease> = new Map();

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

      const uid = url.searchParams.get("uid");
      if (!uid) return new Response("Missing UID", { status: 400 });

      const webSocketPair = new WebSocketPair();
      const [client, server] = Object.values(webSocketPair);

      await this.handleSession(server, uid);
      return new Response(null, { status: 101, webSocket: client });
    }

    return new Response("Not found", { status: 404 });
  }

  private async handleSession(ws: WebSocket, uid: string): Promise<void> {
    ws.accept();
    // Replace any stale wire for this uid (old socket without close event).
    const stale = this.sockets.get(uid);
    if (stale && stale.ws !== ws) {
      try { stale.ws.close(4000, "replaced"); } catch { /* already dead */ }
    }
    this.sockets.set(uid, { ws, lastSeen: Date.now() });

    // Deliver queued ephemeral messages stored persistently in DO storage
    await this.flushEphemeralQueue(ws, uid);

    // Also flush group inboxes for all groups this user belongs to.
    await this.flushGroupInboxes(ws, uid);

    ws.addEventListener("message", async (event) => {
      try {
        const data = JSON.parse(event.data as string);

        if (data.action === "ping") {
          // Heartbeat refreshes the wire lease.
          const lease = this.sockets.get(uid);
          if (lease) lease.lastSeen = Date.now();
          ws.send(JSON.stringify({ type: "pong", timestamp: Date.now() }));
          return;
        }

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
          const { groupId, groupName, encryptedPayload, packetId, senderName } = data;
          if (!groupId || !packetId) {
            ws.send(JSON.stringify({ type: "error", message: "Missing groupId or packetId" }));
            return;
          }

          // Store ONE copy in group inbox (keyed by groupId, not by memberUid)
          const groupKey = `grp:${groupId}:${packetId}`;
          await this.state.storage.put(groupKey, {
            id: packetId,
            senderUid: uid,
            groupId,
            groupName: groupName || "",
            payload: encryptedPayload,
            timestamp: Date.now(),
          } as EphemeralPacket & { groupId: string; groupName: string });

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
                groupName: groupName || "",
                packetId,
                payload: encryptedPayload,
                timestamp: Date.now(),
              }));
            } else {
              // Member offline — FCM wake with group context
              await this.dispatchGroupPushWake(memberUid, uid, groupId, groupName || "", senderName || "");
              wokenCount++;
            }
          }

          console.log(`[relay] group_packet ${packetId} for ${groupId}: ${members.length} members, ${wokenCount} wakes`);
          ws.send(JSON.stringify({ type: "packet_status", packetId, status: "relayed" }));
          return;
        }

        // ─── REGISTER GROUP: store membership for wake routing ───
        if (data.action === "register_group") {
          const { groupId, groupName, memberUids } = data;
          if (!groupId || !Array.isArray(memberUids)) return;

          await this.registerGroupMembership(groupId, groupName || "", memberUids);
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
    });
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
          groupName: msg.groupName || "",
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

  // ─── GROUP MEMBERSHIP: D1 storage ───
  private async registerGroupMembership(
    groupId: string,
    groupName: string,
    memberUids: string[]
  ): Promise<void> {
    if (!this.env.DB) return;
    try {
      // Upsert all members — use batch for efficiency
      const stmts = memberUids.map(uid =>
        this.env.DB.prepare(
          `INSERT OR REPLACE INTO group_memberships (group_id, member_uid, group_name, created_at)
           VALUES (?, ?, ?, ?)`
        ).bind(groupId, uid, groupName, Date.now())
      );
      await this.env.DB.batch(stmts);
    } catch (e) {
      console.log(`[relay] register_group failed: ${e}`);
    }
  }

  private async getGroupMembers(groupId: string): Promise<string[]> {
    if (!this.env.DB) return [];
    try {
      const rows = await this.env.DB.prepare(
        "SELECT member_uid FROM group_memberships WHERE group_id = ?"
      ).bind(groupId).all();
      return rows.results?.map((r: any) => r.member_uid as string) ?? [];
    } catch {
      return [];
    }
  }

  private async getUserGroupIds(uid: string): Promise<string[]> {
    if (!this.env.DB) return [];
    try {
      const rows = await this.env.DB.prepare(
        "SELECT DISTINCT group_id FROM group_memberships WHERE member_uid = ?"
      ).bind(uid).all();
      return rows.results?.map((r: any) => r.group_id as string) ?? [];
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

    if (toDelete.length > 0) {
      await this.state.storage.delete(toDelete);
    }

    // Notify each sender: live wire gets a WS event, offline gets a push.
    for (const [senderUid, info] of expiredBySender) {
      await this.notifySenderOfExpiry(senderUid, info.recipientUid, info.packetIds);
    }

    // Reschedule alarm only if messages remain
    const remaining = await this.state.storage.list({ prefix: "msg:", limit: 1 });
    const remainingGroup = await this.state.storage.list({ prefix: "grp:", limit: 1 });
    if (remaining.size > 0 || remainingGroup.size > 0) {
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

  // FCM Silent Data-only Push Wake Notification (containing zero message content)
  private async dispatchSilentPushWake(recipientUid: string, senderUid: string): Promise<void> {
    try {
      // Single query: recipient's push token + sender's display name (so the
      // client can render the notification without a directory round-trip).
      const row: { fcm_token: string | null; sender_username: string | null } | null =
        await this.env.DB.prepare(
          `SELECT r.fcm_token AS fcm_token, s.username AS sender_username
           FROM users r
           LEFT JOIN users s ON s.uid = ?2
           WHERE r.uid = ?1`
        ).bind(recipientUid, senderUid).first();

      const fcmToken = row?.fcm_token;
      if (!fcmToken) {
        console.log(`[relay] wake skip: no fcm token for ${recipientUid}`);
        return;
      }

      const ok = await sendSilentWake(this.env, fcmToken, senderUid, row?.sender_username ?? undefined);
      console.log(`[relay] wake sent=${ok} to ${recipientUid}`);
    } catch {
      // Ignore push dispatch errors if FCM is unconfigured
    }
  }

  // FCM push wake for group messages — includes groupId + groupName + senderName
  private async dispatchGroupPushWake(
    recipientUid: string,
    senderUid: string,
    groupId: string,
    groupName: string,
    senderName: string,
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

      const ok = await sendGroupWake(this.env, fcmToken, senderUid, senderName, groupId, groupName);
      console.log(`[relay] group wake sent=${ok} to ${recipientUid} for group ${groupId}`);
    } catch {
      // Ignore push dispatch errors
    }
  }
}
