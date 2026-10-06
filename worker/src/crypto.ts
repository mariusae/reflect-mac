// The relay's cryptography, on the Web Crypto every Worker has: GitHub's
// webhook signatures checked, and APNs' tokens signed. Kept apart from the
// rest so that Node's tests can run it as it is.

const encoder = new TextEncoder();

export function hex(bytes: ArrayBuffer | Uint8Array): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function base64url(bytes: ArrayBuffer | Uint8Array | string): string {
  const data = typeof bytes === "string" ? encoder.encode(bytes) : new Uint8Array(bytes);
  let binary = "";
  for (const b of data) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// Two strings compared in time that does not depend on where they differ.
export function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return difference === 0;
}

/// Whether a webhook's body is GitHub's: its `X-Hub-Signature-256` header,
/// `sha256=` and the body's HMAC under the webhook's secret.
export async function isGitHubSigned(body: string, signature: string | null, secret: string): Promise<boolean> {
  if (!signature?.startsWith("sha256=") || !secret) return false;
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(body));
  return sameText(signature.slice("sha256=".length), hex(mac));
}

export async function sha256(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
}

/// The DER inside a PEM — the .p8 key Apple gives.
export function pemBody(pem: string): Uint8Array {
  const base64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const binary = atob(base64);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

/// The token APNs takes in place of a certificate: a JWT signed with the
/// team's key, ES256. Web Crypto's ECDSA signature is already the raw r‖s
/// a JWT wants.
export async function apnsToken(key: string, keyID: string, teamID: string, now = Date.now()): Promise<string> {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyID }));
  const claims = base64url(JSON.stringify({ iss: teamID, iat: Math.floor(now / 1000) }));
  const signingKey = await crypto.subtle.importKey("pkcs8", pemBody(key), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signingKey, encoder.encode(`${header}.${claims}`));
  return `${header}.${claims}.${base64url(signature)}`;
}
