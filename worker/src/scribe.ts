// Dictation's tokens: ElevenLabs' realtime transcription, reached by the
// phone with a single-use token the relay asks ElevenLabs for — so the
// account's key stays here, in a secret, and never ships in an app.

/// Whether a GitHub user may dictate: one of the comma-separated logins
/// allowed, case aside. None allowed, no one may.
export function mayDictate(login: string, allowed: string | undefined): boolean {
  const logins = (allowed ?? "").split(",").map((l) => l.trim().toLowerCase()).filter(Boolean);
  return logins.includes(login.toLowerCase());
}

/// A single-use token for one realtime transcription, good for 15 minutes.
export async function realtimeToken(apiKey: string): Promise<string> {
  const answer = await fetch("https://api.elevenlabs.io/v1/single-use-token/realtime_scribe", {
    method: "POST",
    headers: { "xi-api-key": apiKey },
  });
  if (!answer.ok) {
    console.error("ElevenLabs refused a token", answer.status, await answer.text());
    throw new Response("ElevenLabs refused a token\n", { status: 502 });
  }
  const { token } = (await answer.json()) as { token?: string };
  if (!token) throw new Response("ElevenLabs gave no token\n", { status: 502 });
  return token;
}
