// Model `scripted/assistant`: an offline model for tests and for trying the app without a key. It
// streams slowly enough to abort, and calls tools on cue:
//   "event …"     → calendar_create_event (asks for approval), then reports the result
//   "calendar …"  → calendar_query for today, then reports how many events came back
//   "health …"    → health_query for today's steps
//   "slow …"      → a long answer, for abort
//   anything else → "You said: …"

import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";

type Transcript = { messages: { role: string; content?: unknown; toolName?: string; isError?: boolean }[] };

function text(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((block: { type?: string; text?: string }) => (block.type === "text" ? (block.text ?? "") : "")).join("");
}

function today(hour: number): string {
	const date = new Date();
	date.setHours(hour, 0, 0, 0);
	const offset = -date.getTimezoneOffset();
	const pad = (n: number) => String(Math.floor(Math.abs(n))).padStart(2, "0");
	const local = new Date(date.getTime() + offset * 60_000).toISOString().slice(0, 19);
	return `${local}${offset >= 0 ? "+" : "-"}${pad(offset / 60)}:${pad(offset % 60)}`;
}

const longAnswer = Array.from(
	{ length: 60 },
	(_, i) => `Sentence ${i + 1} of a long answer that streams slowly, so there is time to stop it.`,
).join(" ");

export function createScriptedModel() {
	const faux = fauxProvider({
		provider: "scripted",
		models: [{ id: "assistant", name: "Offline demo (scripted)" }],
		tokensPerSecond: 120,
		tokenSize: { min: 2, max: 6 },
	});
	const step = (transcript: Transcript) => {
		const messages = transcript.messages;
		let lastUser = -1;
		messages.forEach((m, i) => {
			if (m.role === "user") lastUser = i;
		});
		const prompt = text(messages[lastUser]?.content).trim();
		const results = messages.slice(lastUser + 1).filter((m) => m.role === "toolResult");
		const word = prompt.toLowerCase().split(/\s+/)[0] ?? "";
		if (results.length > 0) {
			const summary = results.map((r) => `${r.toolName}: ${r.isError ? "error" : "ok"} — ${text(r.content).slice(0, 200)}`);
			return fauxAssistantMessage(`Tool results:\n${summary.join("\n")}`);
		}
		switch (word) {
			case "event":
				return fauxAssistantMessage(
					fauxToolCall("calendar_create_event", { title: prompt.slice(6) || "Pi test event", start: today(15), end: today(16) }),
					{ stopReason: "toolUse" },
				);
			case "calendar":
				return fauxAssistantMessage(fauxToolCall("calendar_query", { start: today(0), end: today(24) }), { stopReason: "toolUse" });
			case "health":
				return fauxAssistantMessage(fauxToolCall("health_query", { metric: "steps", start: today(0), end: today(24) }), {
					stopReason: "toolUse",
				});
			case "slow":
				return fauxAssistantMessage(longAnswer);
			default:
				return fauxAssistantMessage(`You said: ${prompt}`);
		}
	};
	// Every request consumes one step; each step is the same function of the transcript.
	faux.setResponses(Array.from({ length: 10_000 }, () => step as never));
	return faux;
}
