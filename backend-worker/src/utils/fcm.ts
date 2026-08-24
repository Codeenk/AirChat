// FCM HTTP v1 API client for Cloudflare Workers.
// Uses service-account JWT -> OAuth2 access-token exchange.
// Legacy server keys are deprecated by Google (June 2024); v1 is required for new projects.

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id?: string;
}

const OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token";
const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

// Access tokens live ~1 hour; cache per isolate to avoid re-signing every message.
let cachedToken: { token: string; expiresAt: number } | null = null;

function base64UrlEncode(input: string | Uint8Array): string {
  let bytes: Uint8Array;
  if (typeof input === "string") {
    bytes = new TextEncoder().encode(input);
  } else {
    bytes = input;
  }
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8Der(pem: string): Uint8Array {
  const body = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export async function getFcmAccessToken(serviceAccountJson: string): Promise<string> {
  const now = Date.now();
  if (cachedToken && cachedToken.expiresAt > now + 60_000) {
    return cachedToken.token;
  }

  const sa: ServiceAccount = JSON.parse(serviceAccountJson);

  const issuedAt = Math.floor(now / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: FCM_SCOPE,
    aud: OAUTH_TOKEN_URL,
    iat: issuedAt,
    exp: issuedAt + 3600,
  };

  const unsignedJwt =
    `${base64UrlEncode(JSON.stringify(header))}.${base64UrlEncode(JSON.stringify(claims))}`;

  const pkcs8 = pemToPkcs8Der(sa.private_key);
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    pkcs8,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const signatureBuffer = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    privateKey,
    new TextEncoder().encode(unsignedJwt),
  );

  const jwt = `${unsignedJwt}.${base64UrlEncode(new Uint8Array(signatureBuffer))}`;

  const res = await fetch(OAUTH_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }).toString(),
  });

  if (!res.ok) {
    throw new Error(`FCM token exchange failed: ${res.status} ${await res.text()}`);
  }

  const data = (await res.json()) as { access_token: string; expires_in: number };
  cachedToken = {
    token: data.access_token,
    expiresAt: now + data.expires_in * 1000,
  };
  return data.access_token;
}

// Sends a silent (data-only) wake-up push. Contains zero message content —
// only the sender's uid and public display name (directory metadata) so the
// client can render the notification instantly without any DB/network work
// in the cold-start background isolate.
export async function sendSilentWake(
  env: { FCM_SERVICE_ACCOUNT_JSON?: string; FCM_PROJECT_ID?: string },
  fcmToken: string,
  senderUid: string,
  senderName?: string,
): Promise<boolean> {
  if (!env.FCM_SERVICE_ACCOUNT_JSON || !env.FCM_PROJECT_ID) {
    return false; // Push not configured; queued messages still deliver on next app open
  }

  try {
    const accessToken = await getFcmAccessToken(env.FCM_SERVICE_ACCOUNT_JSON);

    const res = await fetch(
      `https://fcm.googleapis.com/v1/projects/${env.FCM_PROJECT_ID}/messages:send`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          message: {
            token: fcmToken,
            data: {
              type: "wake",
              senderUid,
              ...(senderName ? { senderName } : {}),
            },
            // Notification payload: displayed by the OS itself — delivered
            // even when the app process is killed (data-only pushes are
            // frequently dropped by Doze/OEM battery managers).
            notification: {
              title: senderName ?? "AirChat",
              body: "You have a new message",
            },
            android: {
              priority: "HIGH",
              notification: {
                channel_id: "airchat_messages",
                tag: senderUid,
              },
            },
            apns: {
              payload: { aps: { contentAvailable: true, alert: {
                title: senderName ?? "AirChat",
                body: "You have a new message",
              } } },
              headers: { "apns-push-type": "background", "apns-priority": "5" },
            },
          },
        }),
      },
    );

    return res.ok;
  } catch {
    return false; // Never fail message queuing because of push errors
  }
}
