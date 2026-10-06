// A repository's hub: the iPhones to push to, kept in its storage; the Macs
// listening, as WebSockets it holds — asleep between pushes, the sockets
// kept open by Cloudflare meanwhile.

import { DurableObject } from "cloudflare:workers";
import { apnsToken } from "./crypto.ts";
import type { APNsConfig, Env } from "./index.ts";

export interface Device {
  environment: "production" | "sandbox";
  /// The app's bundle identifier.
  topic: string;
}

export interface Told {
  listening: number;
  pushed: number;
  forgotten: number;
}

/// APNs' answers that mean a token will never be good again.
const goneReasons = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "ExpiredToken"]);

export class RepoHub extends DurableObject<Env> {
  /// The APNs token, signed once and used for most of an hour: Apple turns
  /// away one made more often than every twenty minutes.
  private signed: { token: string; at: number } | null = null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // A Mac's keep-alive answered without waking the hub.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async remember(token: string, device: Device): Promise<void> {
    await this.ctx.storage.put(`device:${token}`, device);
  }

  async forget(token: string): Promise<void> {
    await this.ctx.storage.delete(`device:${token}`);
  }

  /// A Mac's WebSocket, held.
  async fetch(_request: Request): Promise<Response> {
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(): Promise<void> {}

  async webSocketClose(socket: WebSocket, code: number): Promise<void> {
    try {
      socket.close(code, "closing");
    } catch {}
  }

  /// The repository was pushed to: every Mac listening told, and every
  /// iPhone sent a silent push. Tokens APNs says are dead let go.
  async pushed(after: string, apns: APNsConfig | null): Promise<Told> {
    const message = JSON.stringify({ type: "push", after });
    const sockets = this.ctx.getWebSockets();
    for (const socket of sockets) {
      try {
        socket.send(message);
      } catch {}
    }
    const told: Told = { listening: sockets.length, pushed: 0, forgotten: 0 };
    if (!apns) return told;
    const devices = await this.ctx.storage.list<Device>({ prefix: "device:" });
    const authorization = `bearer ${await this.apnsToken(apns)}`;
    await Promise.all(
      [...devices].map(async ([key, device]) => {
        const token = key.slice("device:".length);
        const host = device.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
        const answer = await fetch(`https://${host}/3/device/${token}`, {
          method: "POST",
          headers: {
            authorization,
            "apns-topic": device.topic,
            "apns-push-type": "background",
            // Background pushes must go at the lower priority.
            "apns-priority": "5",
            // Kept a few hours for a phone out of reach; pushes not yet
            // delivered fold into the latest.
            "apns-expiration": String(Math.floor(Date.now() / 1000) + 6 * 3600),
            "apns-collapse-id": "sync",
          },
          body: JSON.stringify({ aps: { "content-available": 1 }, after }),
        });
        if (answer.ok) {
          told.pushed++;
          return;
        }
        const reason = ((await answer.json().catch(() => ({}))) as { reason?: string }).reason ?? "";
        if (answer.status === 410 || goneReasons.has(reason)) {
          await this.ctx.storage.delete(key);
          told.forgotten++;
        } else {
          console.warn(`APNs turned a push away: ${answer.status} ${reason}`);
        }
      }),
    );
    return told;
  }

  private async apnsToken(apns: APNsConfig): Promise<string> {
    const now = Date.now();
    if (!this.signed || now - this.signed.at > 40 * 60 * 1000) {
      this.signed = { token: await apnsToken(apns.key, apns.keyID, apns.teamID, now), at: now };
    }
    return this.signed.token;
  }
}
