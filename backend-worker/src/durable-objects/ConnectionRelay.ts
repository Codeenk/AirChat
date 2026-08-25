export interface EphemeralPacket {
  id: string;
  senderUid: string;
  recipientUid: string;
  payload: string;
  timestamp: number;
}

import { sendSilentWake } from "../utils/fcm";

export class ConnectionRelay {
  private state: DurableObjectState;
  private env: any;
  private sockets: Map<string, WebSocket> = new Map();

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
    this.sockets.set(uid, ws);

    // Deliver queued ephemeral messages stored persistently in DO storage
    await this.flushEphemeralQueue(ws, uid);

    ws.addEventListener("message", async (event) => {
      try {
        const data = JSON.parse(event.data as string);

        if (data.action === "ping") {
          ws.send(JSON.stringify({ type: "pong", timestamp: Date.now() }));
          return;
        }

        if (data.action === "send_packet") {
          const { recipientUid, encryptedPayload, packetId } = data;
          const targetWs = this.sockets.get(recipientUid);

          if (targetWs && targetWs.readyState === WebSocket.READY_STATE_OPEN) {
            // Direct real-time WebSocket delivery (same shard or within-session)
            targetWs.send(JSON.stringify({
              type: "direct_message",
              senderUid: uid,
              packetId,
              payload: encryptedPayload,
              timestamp: Date.now()
            }));

            // Immediate ACK to sender
            ws.send(JSON.stringify({ type: "packet_status", packetId, status: "relayed" }));
          } else {
            // Recipient on different shard or offline -> Buffer in DO storage
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

        if (data.action === "ack") {
          const { packetId, senderUid } = data;
          await this.state.storage.delete(`msg:${uid}:${packetId}`);

          const senderWs = this.sockets.get(senderUid);
          if (senderWs && senderWs.readyState === WebSocket.READY_STATE_OPEN) {
            senderWs.send(JSON.stringify({ type: "delivery_receipt", packetId, status: "delivered" }));
          }
        }

        if (data.action === "read_receipt") {
          const { packetId, senderUid } = data;
          if (!packetId || !senderUid) return;

          // Best-effort: notify the original sender that their message was read.
          const senderWs = this.sockets.get(senderUid);
          if (senderWs && senderWs.readyState === WebSocket.READY_STATE_OPEN) {
            senderWs.send(JSON.stringify({ type: "read_receipt", packetId }));
          }
        }
      } catch (err) {
        ws.send(JSON.stringify({ type: "error", message: "Malformed packet" }));
      }
    });

    ws.addEventListener("close", () => {
      this.sockets.delete(uid);
    });
  }

  private async enqueueEphemeralPacket(packet: EphemeralPacket): Promise<void> {
    const key = `msg:${packet.recipientUid}:${packet.id}`;
    await this.state.storage.put(key, packet);

    const currentAlarm = await this.state.storage.getAlarm();
    if (!currentAlarm) {
      await this.state.storage.setAlarm(Date.now() + 24 * 60 * 60 * 1000);
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

  // Durable Object 24-hour cleanup alarm handler
  async alarm(): Promise<void> {
    const now = Date.now();
    const cutoff = now - 24 * 60 * 60 * 1000;
    const allMessages = await this.state.storage.list<EphemeralPacket>({ prefix: "msg:" });

    const toDelete: string[] = [];
    for (const [key, packet] of allMessages) {
      if (packet.timestamp < cutoff) {
        toDelete.push(key);
      }
    }

    if (toDelete.length > 0) {
      await this.state.storage.delete(toDelete);
    }

    // Reschedule alarm
    await this.state.storage.setAlarm(Date.now() + 24 * 60 * 60 * 1000);
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
}