// Model `scripted/assistant`: an offline model for tests and for trying the app without a key. It
// streams slowly enough to abort, and calls tools on cue:
//   "event …"     → calendar_create_event (asks for approval), then reports the result
//   "calendar …"  → calendar_query for today, then reports how many events came back
//   "health …"    → health_query for today's steps
//   "slow …"      → a long answer, for abort
//   "widget …"    → create_surface (a morning widget), then publish_surface (asks for approval)
//   "card …"      → create_surface (a checklist card shown in the chat)
//   "repair …"    → create_surface with an error (a Ring without goal), then patch_surface to fix it
//   "schedule …"  → schedule_task "nudge" in 3 seconds, once, with a notification; its run calls set_value nudge
//   "remind …"    → notify_schedule in a minute
//   "todo …"      → reminders_create due today at 18:00 (asks for approval)
//   "where …"     → location_current
//   "search …"    → web_search for the rest of the prompt
//   "read <url>"  → web_fetch the URL (asks unless the conversation already holds it)
//   "follow …"    → web_fetch a URL that the offline search only mentions in a snippet (asks)
//   "tasks …"     → reminders_query for what is due by the end of today
//   "photos …"    → photos_search for the rest of the prompt
//   "markdown …"  → a short thought, then an answer with headings, lists, a table, a quote and code
//   "chores …"    → create_surface and publish_surface for a widget whose checklist rows complete open reminders
//   "habits …"    → set_value habits (a to-do list), then create_surface and publish_surface for a widget whose checklist
//                   rows toggle it and whose buttons reset it or send a prompt
//   "skill <name>" → skill_read the skill
//   "skillfile <name> <path>" → skill_file a file of the skill
//   "section <key>" → answers with the system prompt section `key` as it stands (or "(none)")
//   anything else → "You said: …"

import { fauxAssistantMessage, fauxProvider, fauxText, fauxThinking, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";

type Transcript = {
	messages: { role: string; content?: unknown; toolName?: string; isError?: boolean; sections?: Record<string, string | null> }[];
};

/** A system prompt section as the transcript's system messages leave it: later messages replace, `null` removes. */
function sectionText(messages: Transcript["messages"], key: string): string | undefined {
	let value: string | undefined;
	for (const message of messages) {
		if (message.role !== "system" || message.sections === undefined || !(key in message.sections)) continue;
		value = message.sections[key] ?? undefined;
	}
	return value;
}

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

const habits = [{ title: "Water" }, { title: "Walk" }, { title: "Read" }];

const habitsSpec = {
	title: "Habits",
	surface: "widget",
	families: ["systemMedium", "systemLarge"],
	slots: [
		{ c: "Checklist", items: "$doc.habits", title: "Today" },
		{
			c: "ActionRow",
			actions: [
				{ title: "Reset", set: "habits", value: habits, symbol: "arrow.counterclockwise" },
				{ title: "Plan", prompt: "Plan my evening around my habits.", symbol: "sparkles" },
			],
		},
	],
};

const choresSpec = {
	title: "Chores",
	surface: "widget",
	families: ["systemMedium", "systemLarge"],
	slots: [{ c: "Checklist", items: "$reminders.open", title: "Reminders" }],
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

const markdownAnswer = [
	"## Your evening",
	"",
	"You have **three** things left, and one is *overdue*:",
	"",
	"1. Pick up the `plastic bag` for the storage unit",
	"2. Defrost dinner",
	"   - check the freezer first",
	"   - leave it in the fridge",
	"3. Brush the kids' teeth",
	"",
	"> Tip: tick them off right in the card.",
	"",
	"| When | What |",
	"|:--|--:|",
	"| 19:00 | Dinner |",
	"| 22:00 | Bed |",
	"",
	"```swift",
	'let greeting = "Hello"',
	"print(greeting)",
	"```",
	"",
	"---",
	"See [Reminders](https://www.icloud.com/reminders) for the rest.",
].join("\n");

const longAnswer = Array.from(
	{ length: 60 },
	(_, i) => `Sentence ${i + 1} of a long answer that streams slowly, so there is time to stop it.`,
).join(" ");

export function createScriptedModel() {
	const faux = fauxProvider({
		provider: "scripted",
		// Reasoning, so the effort picker can be tried offline; the faux provider ignores the level.
		// Image input too, so attachments reach it as images and its answer can count them.
		models: [{ id: "assistant", name: "Offline demo (scripted)", reasoning: true, input: ["text", "image"] }],
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
		if (word === "habits" && results.length === 1 && results[0]!.toolName === "set_value") {
			return fauxAssistantMessage(fauxToolCall("create_surface", { spec: habitsSpec as never }), { stopReason: "toolUse" });
		}
		const habitsSurface = word === "habits" && results.length === 2 && !results[1]!.isError ? surfaceId(results[1]!.content) : undefined;
		if (habitsSurface !== undefined) {
			return fauxAssistantMessage(fauxToolCall("publish_surface", { id: habitsSurface }), { stopReason: "toolUse" });
		}
		if ((word === "widget" || word === "chores") && created !== undefined) {
			return fauxAssistantMessage(fauxToolCall("publish_surface", { id: created }), { stopReason: "toolUse" });
		}
		if (word === "repair" && created !== undefined) {
			return fauxAssistantMessage(
				fauxToolCall("patch_surface", { id: created, baseVersion: 1, patch: [{ op: "add", path: "/slots/0/goal", value: 8 }] }),
				{ stopReason: "toolUse" },
			);
		}
		if (prompt.startsWith("[Scheduled task") && prompt.includes("set_value") && results.length === 0) {
			return fauxAssistantMessage(fauxToolCall("set_value", { key: "nudge", value: `Refreshed at ${new Date().toISOString().slice(11, 16)} UTC` }), {
				stopReason: "toolUse",
			});
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
			case "chores":
				return fauxAssistantMessage(fauxToolCall("create_surface", { spec: choresSpec as never }), { stopReason: "toolUse" });
			case "card":
				return fauxAssistantMessage(fauxToolCall("create_surface", { spec: cardSpec as never }), { stopReason: "toolUse" });
			case "repair":
				return fauxAssistantMessage(
					fauxToolCall("create_surface", { spec: { surface: "card", slots: [{ c: "Ring", value: 5, label: "Glasses" }] } as never }),
					{ stopReason: "toolUse" },
				);
			case "schedule":
				return fauxAssistantMessage(
					fauxToolCall("schedule_task", {
						name: "nudge",
						prompt: "Write a new nudge with set_value nudge.",
						at: new Date(Date.now() + 3000).toISOString(),
						notify: true,
					}),
					{ stopReason: "toolUse" },
				);
			case "habits":
				return fauxAssistantMessage(fauxToolCall("set_value", { key: "habits", value: habits as never }), { stopReason: "toolUse" });
			case "tasks":
				return fauxAssistantMessage(fauxToolCall("reminders_query", { dueBefore: today(24) }), { stopReason: "toolUse" });
			case "markdown":
				return fauxAssistantMessage([fauxThinking("They want formatting. A list, a table and some code."), fauxText(markdownAnswer)]);
			case "photos":
				return fauxAssistantMessage(fauxToolCall("photos_search", { query: prompt.slice(7) || "a sunset" }), { stopReason: "toolUse" });
			case "where":
				return fauxAssistantMessage(fauxToolCall("location_current", {}), { stopReason: "toolUse" });
			case "search":
				return fauxAssistantMessage(fauxToolCall("web_search", { query: prompt.slice(7) || "pi durable" }), { stopReason: "toolUse" });
			case "follow":
				return fauxAssistantMessage(fauxToolCall("web_fetch", { url: "https://example.com/from-a-snippet" }), { stopReason: "toolUse" });
			case "read":
				return fauxAssistantMessage(fauxToolCall("web_fetch", { url: prompt.slice(5).trim() || "https://earendil.com/posts/pi-durable/" }), {
					stopReason: "toolUse",
				});
			case "todo":
				return fauxAssistantMessage(fauxToolCall("reminders_create", { title: prompt.slice(5) || "Pi test reminder", due: today(18) }), {
					stopReason: "toolUse",
				});
			case "remind":
				return fauxAssistantMessage(
					fauxToolCall("notify_schedule", { title: "Pi reminder", body: prompt.slice(7) || "Stretch", at: new Date(Date.now() + 60_000).toISOString() }),
					{ stopReason: "toolUse" },
				);
			case "slow":
				return fauxAssistantMessage(longAnswer);
			case "skill":
				return fauxAssistantMessage(fauxToolCall("skill_read", { name: prompt.split(/\s+/)[1] ?? "" }), { stopReason: "toolUse" });
			case "skillfile": {
				const [, name = "", path = ""] = prompt.split(/\s+/);
				return fauxAssistantMessage(fauxToolCall("skill_file", { name, path }), { stopReason: "toolUse" });
			}
			case "section": {
				const key = prompt.split(/\s+/)[1] ?? "";
				return fauxAssistantMessage(`Section ${key}: ${sectionText(messages, key) ?? "(none)"}`);
			}
			default: {
				const content = messages[lastUser]?.content;
				const images = Array.isArray(content) ? content.filter((block: { type?: string }) => block.type === "image").length : 0;
				return fauxAssistantMessage(images === 0 ? `You said: ${prompt}` : `You said: ${prompt}\n\n(${images} image${images === 1 ? "" : "s"} attached)`);
			}
		}
	};
	// Every request consumes one step; each step is the same function of the transcript.
	faux.setResponses(Array.from({ length: 10_000 }, () => step as never));
	return faux;
}
