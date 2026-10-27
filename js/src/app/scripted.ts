// Model `scripted/assistant`: an offline model for tests and for trying the app without a key. It
// streams slowly enough to abort, and calls tools on cue:
//   "event …"     → calendar_create_event (asks for approval), then reports the result
//   "calendar …"  → calendar_query for today, then reports how many events came back
//   "health …"    → health_query for today's steps
//   "slow …"      → a long answer, for abort
//   "widget …"    → create_surface (a morning widget), then publish_surface (asks for approval)
//   "card …"      → create_surface (a checklist card shown in the chat)
//   "repair …"    → create_surface with an error (a Ring without goal), then patch_surface to fix it
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

const widgetSpec = {
	title: "Morning",
	surface: "widget",
	families: ["systemMedium", "systemSmall", "accessoryRectangular"],
	slots: [
		{ c: "Ring", value: "$health.stepsToday", goal: 10000, symbol: "figure.walk", label: "Steps" },
		{ c: "NextUp", source: "$calendar.next", families: ["systemMedium", "accessoryRectangular"] },
		{ c: "Quote", text: "Small steps count.", emphasis: "secondary", families: ["systemMedium"] },
	],
};

const cardSpec = {
	title: "Today",
	surface: "card",
	slots: [
		{ c: "Header", title: "Today's plan", symbol: "checklist" },
		{ c: "Checklist", items: [{ title: "Walk 20 minutes", done: true }, { title: "Reply to Sam" }, { title: "Groceries" }] },
	],
};

/** The surface id in a create_surface result (`{"id": "s1", …}`). */
function surfaceId(content: unknown): string | undefined {
	try {
		return (JSON.parse(text(content)) as { id?: string }).id;
	} catch {
		return undefined;
	}
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
		const created = results.length === 1 && results[0]!.toolName === "create_surface" && !results[0]!.isError ? surfaceId(results[0]!.content) : undefined;
		if (word === "widget" && created !== undefined) {
			return fauxAssistantMessage(fauxToolCall("publish_surface", { id: created }), { stopReason: "toolUse" });
		}
		if (word === "repair" && created !== undefined) {
			return fauxAssistantMessage(
				fauxToolCall("patch_surface", { id: created, baseVersion: 1, patch: [{ op: "add", path: "/slots/0/goal", value: 8 }] }),
				{ stopReason: "toolUse" },
			);
		}
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
			case "widget":
				return fauxAssistantMessage(fauxToolCall("create_surface", { spec: widgetSpec as never }), { stopReason: "toolUse" });
			case "card":
				return fauxAssistantMessage(fauxToolCall("create_surface", { spec: cardSpec as never }), { stopReason: "toolUse" });
			case "repair":
				return fauxAssistantMessage(
					fauxToolCall("create_surface", { spec: { surface: "card", slots: [{ c: "Ring", value: 5, label: "Glasses" }] } as never }),
					{ stopReason: "toolUse" },
				);
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
