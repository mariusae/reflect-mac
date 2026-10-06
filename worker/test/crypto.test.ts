import assert from "node:assert/strict";
import { test } from "node:test";
import { apnsToken, base64url, isGitHubSigned, pemBody } from "../src/crypto.ts";

test("GitHub's own example signature is accepted, and a wrong one is not", async () => {
  // From GitHub's documentation on validating webhook deliveries.
  const secret = "It's a Secret to Everybody";
  const body = "Hello, World!";
  const signature = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17";
  assert.equal(await isGitHubSigned(body, signature, secret), true);
  assert.equal(await isGitHubSigned(body + " ", signature, secret), false);
  assert.equal(await isGitHubSigned(body, null, secret), false);
  assert.equal(await isGitHubSigned(body, signature, ""), false);
});

test("an APNs token is a JWT its key's public half verifies", async () => {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8)).replace(/(.{64})/g, "$1\n")}\n-----END PRIVATE KEY-----\n`;
  assert.deepEqual(pemBody(pem), pkcs8);

  const token = await apnsToken(pem, "KEY123", "TEAM456", 1_700_000_000_000);
  const [header, claims, signature] = token.split(".");
  const decode = (part: string) => JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
  assert.deepEqual(decode(header), { alg: "ES256", kid: "KEY123" });
  assert.deepEqual(decode(claims), { iss: "TEAM456", iat: 1_700_000_000 });
  const raw = Uint8Array.from(atob(signature.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
  assert.equal(raw.length, 64);
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, raw, new TextEncoder().encode(`${header}.${claims}`));
  assert.equal(ok, true);
});

test("base64url has no padding or URL-unsafe characters", () => {
  assert.equal(base64url(new Uint8Array([0xfb, 0xff])), "-_8");
});
