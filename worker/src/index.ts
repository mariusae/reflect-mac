// The sync relay's front: GitHub's webhook in, devices registering, Macs
// listening. Each repository's own state is its hub's (hub.ts).

import { isGitHubSigned, sha256 } from "./crypto.ts";
import { RepoHub, type Device } from "./hub.ts";

export { RepoHub };

export interface Env {
  HUBS: DurableObjectNamespace<RepoHub>;
  GITHUB_WEBHOOK_SECRET: string;
  APNS_KEY: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  /// Comma-separated: the apps' bundle identifiers an iPhone may register for.
  APNS_TOPICS: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/github" && request.method === "POST") return await webhook(request, env);
      if (url.pathname === "/devices" && (request.method === "POST" || request.method === "DELETE")) return await devices(request, env);
      if (url.pathname === "/events") return await events(request, env, url);
      if (url.pathname === "/" && request.method === "GET") return new Response("reflect-sync-relay\n");
      return new Response("Not found\n", { status: 404 });
    } catch (error) {
      if (error instanceof Response) return error;
      console.error(error);
      return new Response("Something went wrong\n", { status: 500 });
    }
  },
} satisfies ExportedHandler<Env>;

/// A repository's hub, by GitHub's id for it: renamed or moved, still the one.
function hub(env: Env, repositoryID: number): DurableObjectStub<RepoHub> {
  return env.HUBS.get(env.HUBS.idFromName(String(repositoryID)));
}

// MARK: GitHub

interface PushEvent {
  ref: string;
  after: string;
  repository: { id: number; full_name: string; default_branch: string };
}

/// GitHub, telling of a push: the repository's devices told in turn — when
/// it is to the branch they keep, and GitHub's signature is on it.
async function webhook(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  if (!(await isGitHubSigned(body, request.headers.get("X-Hub-Signature-256"), env.GITHUB_WEBHOOK_SECRET))) {
    return new Response("Bad signature\n", { status: 401 });
  }
  const event = request.headers.get("X-GitHub-Event");
  if (event !== "push") return new Response(`Ignored ${event}\n`, { status: 202 });
  const push = JSON.parse(body) as PushEvent;
  if (push.ref !== `refs/heads/${push.repository.default_branch}`) return new Response("Not the default branch\n", { status: 202 });
  const told = await hub(env, push.repository.id).pushed(push.after, apnsConfig(env));
  return Response.json(told);
}

export interface APNsConfig {
  key: string;
  keyID: string;
  teamID: string;
}

function apnsConfig(env: Env): APNsConfig | null {
  return env.APNS_KEY && env.APNS_KEY_ID && env.APNS_TEAM_ID ? { key: env.APNS_KEY, keyID: env.APNS_KEY_ID, teamID: env.APNS_TEAM_ID } : null;
}

// MARK: Devices

/// The repository a device's GitHub token can read, by its `owner/name`:
/// GitHub's id for it. Asked of GitHub, the answer kept a few minutes; the
/// token itself is never kept.
async function repositoryID(token: string, fullName: string): Promise<number> {
  if (!/^[\w.-]+\/[\w.-]+$/.test(fullName)) throw new Response("Bad repository\n", { status: 400 });
  const cacheKey = new Request(`https://access.cache/${await sha256(token)}/${fullName}`);
  const cache = (caches as unknown as { default: Cache }).default;
  const cached = await cache.match(cacheKey);
  if (cached) return Number(await cached.text());
  const answer = await fetch(`https://api.github.com/repos/${fullName}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "reflect-sync-relay",
      "X-GitHub-Api-Version": "2022-11-28",
    },
  });
  if (!answer.ok) throw new Response("No access to that repository\n", { status: 403 });
  const { id } = (await answer.json()) as { id: number };
  await cache.put(cacheKey, new Response(String(id), { headers: { "Cache-Control": "max-age=600" } }));
  return id;
}

function bearer(request: Request): string {
  const header = request.headers.get("Authorization") ?? "";
  if (!header.startsWith("Bearer ")) throw new Response("Sign in to GitHub first\n", { status: 401 });
  return header.slice("Bearer ".length);
}

interface Registration {
  repository: string;
  token: string;
  environment: "production" | "sandbox";
  topic: string;
}

/// An iPhone, to be pushed to when its graph's repository is pushed to —
/// or, deleted, no longer.
async function devices(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as Partial<Registration>;
  const { repository, token } = body;
  if (!repository || !token || !/^[0-9a-f]{32,200}$/i.test(token)) return new Response("Bad device\n", { status: 400 });
  const id = await repositoryID(bearer(request), repository);
  if (request.method === "DELETE") {
    await hub(env, id).forget(token);
    return new Response(null, { status: 204 });
  }
  const topics = env.APNS_TOPICS.split(",").map((t) => t.trim());
  if (!body.topic || !topics.includes(body.topic)) return new Response("Unknown app\n", { status: 400 });
  const device: Device = { environment: body.environment === "sandbox" ? "sandbox" : "production", topic: body.topic };
  await hub(env, id).remember(token, device);
  return new Response(null, { status: 204 });
}

/// A Mac, listening: a WebSocket its hub holds, told of each push.
async function events(request: Request, env: Env, url: URL): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("Expected a WebSocket\n", { status: 426 });
  const id = await repositoryID(bearer(request), url.searchParams.get("repository") ?? "");
  return hub(env, id).fetch(request);
}
