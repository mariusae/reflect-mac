// Claude, for the apps: a note summed up, or the tasks in it found — the
// account's key kept here, in a secret, never in an app. Only the GitHub
// logins allowed may ask, as for dictation.

import Anthropic from "@anthropic-ai/sdk";

/// What the apps may ask of a note: a few lines summing it up, or the
/// things to do it speaks of.
export type Task = "summarize" | "tasks";

const instructions: Record<Task, string> = {
  summarize:
    "You read one note from someone's outline notes and sum it up for them, to keep at its top. " +
    "Give 1 to 5 short lines, each a plain statement, most important first, in the note's own language. " +
    "No preamble, no bullet characters, no Markdown.",
  tasks:
    "You read one note from someone's outline notes — often a meeting's — and find the things it says someone is to do. " +
    "Give each as a short imperative line, with who is to do it when the note says, in the note's own language. " +
    "Leave out what is already marked done. None at all is a fine answer. No preamble, no bullet characters, no Markdown.",
};

/// The lines Claude gives for a note: its summary's, or its tasks'.
export async function ask(apiKey: string, task: Task, title: string, text: string): Promise<string[]> {
  const client = new Anthropic({ apiKey });
  const response = await client.beta.messages.create({
    model: "claude-opus-5-5",
    max_tokens: 16000,
    // A refusal tried again on another model, chosen by what was refused.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    system: instructions[task],
    output_config: {
      effort: "low",
      format: {
        type: "json_schema",
        schema: {
          type: "object",
          properties: { lines: { type: "array", items: { type: "string" } } },
          required: ["lines"],
          additionalProperties: false,
        },
      },
    },
    messages: [{ role: "user", content: `# ${title}\n\n${text}` }],
  });
  if (response.stop_reason === "refusal") throw new Response("Claude declined to read this note\n", { status: 422 });
  const json = response.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");
  const lines = (JSON.parse(json) as { lines?: unknown }).lines;
  return Array.isArray(lines) ? lines.filter((line): line is string => typeof line === "string" && line.trim() !== "") : [];
}
