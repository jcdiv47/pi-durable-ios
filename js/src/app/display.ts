// Turns a conversation's transcript and documents (`Conversation.watch()`, completed in view.ts) into the small
// display model the SwiftUI transcript renders. Entries are immutable, so frames carry only the entries appended
// since the last frame, plus the whole live state (streamed partial, running tools), which is small.

import type { ModelThinkingLevel } from "@earendil-works/pi-ai";
import type { EntryRecord, InboxState } from "@earendil-works/pi-durable";
import { attachmentSummary, type DisplayAttachment, type InputData } from "./attachments.ts";

export type DisplayToolCall = { id: string; name: string; arguments: string };

export type DisplayItem =
	/** `origin`: where an input from outside the chat came from (Siri, a widget, a schedule). */
	/** `attachments`: what came with the text (the model got them in the message after it). */
	/** `skill`: the skill the user ran with "/" (the model got its body; the bubble shows its name). */
	| { id: number; kind: "user"; text: string; timestamp?: number; origin?: string; attachments?: DisplayAttachment[]; skill?: string }
	| {
			id: number;
			kind: "assistant";
			text: string;
			thinking: string;
			toolCalls: DisplayToolCall[];
			model?: string;
			stopReason?: string;
			error?: string;
			timestamp?: number;
	  }
	| {
			id: number;
			kind: "toolResult";
			callId: string;
			toolName: string;
			text: string;
			isError: boolean;
			timestamp?: number;
			surface?: DisplaySurface;
			/** The parsed output of a tool the chat draws a native card for (`cardTools`). */
			data?: unknown;
	  }
	| { id: number; kind: "notice"; text: string };

/** A queued user message, by submission ID. */
export type DisplayQueued = { id: number; text: string; mode: "steer" | "followUp" };

/** A surface a UI tool made or changed; the chat draws it under the call. */
export type DisplaySurface = { conversationId: number; id: string; version: number; spec: unknown };

export type DisplayLive = {
	busy: boolean;
	generation?: { text: string; thinking: string; toolCalls: DisplayToolCall[]; attempt: number; retry?: { at: number; error: string } };
	tools: { callId: string; name: string; status: string; output?: string }[];
	compacting: boolean;
	compactionError?: string;
};

export type DisplayFrame = {
	conversationId: number;
	/** True when `items` is the whole transcript; otherwise they append to the previous frame's. */
	reset: boolean;
	items: DisplayItem[];
	live: DisplayLive;
	/** Messages waiting in the inbox, oldest first; a `steer` lands at the next tool boundary. */
	queue: DisplayQueued[];
	model?: { provider: string; modelId: string };
	thinkingLevel: ModelThinkingLevel;
	usage: { input: number; output: number; cost: number };
};

/** Display text is bounded; tool results such as a month of calendar events can be long. */
const MAX_TEXT = 6000;

function clip(text: string): string {
	return text.length > MAX_TEXT ? `${text.slice(0, MAX_TEXT)}\n… (${text.length - MAX_TEXT} more characters)` : text;
}

type Block = { type: string; text?: string; thinking?: string; id?: string; name?: string; arguments?: unknown };

/** Tools whose JSON output the chat draws as a card (ResultCards.swift); the text is clipped, the data is not. */
const cardTools = new Set([
	"reminders_query",
	"reminders_create",
	"reminders_update",
	"reminders_complete",
	"calendar_query",
	"calendar_create_event",
	"health_query",
	"location_current",
	"photos_search",
	"web_search",
]);

/** Tools whose structured result is in `details.card` (their text is written for the model). */
const detailCardTools = new Set(["pve_overview", "pve_guests", "pve_backups"]);

/** Larger outputs keep only their text. */
const MAX_DATA = 64_000;

function cardData(toolName: string, isError: boolean, text: string, details: unknown): unknown {
	if (!isError && detailCardTools.has(toolName)) return (details as { card?: unknown } | undefined)?.card;
	if (isError || !cardTools.has(toolName) || text.length > MAX_DATA) return undefined;
	try {
		return JSON.parse(text);
	} catch {
		return undefined;
	}
}

export function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return (content as Block[])
		.map((block) => (block.type === "text" ? (block.text ?? "") : block.type === "image" ? "[image]" : ""))
		.join("");
}

function assistantParts(message: { content?: Block[] } | undefined) {
	const blocks = message?.content ?? [];
	return {
		text: blocks.filter((b) => b.type === "text").map((b) => b.text ?? "").join(""),
		thinking: blocks.filter((b) => b.type === "thinking").map((b) => b.thinking ?? "").join(""),
		toolCalls: blocks
			.filter((b) => b.type === "toolCall")
			.map((b) => ({ id: b.id ?? "", name: b.name ?? "", arguments: JSON.stringify(b.arguments ?? {}) })),
	};
}

export function displayItem(entry: EntryRecord): DisplayItem | undefined {
	const message = entry.model?.[0] as Record<string, unknown> | undefined;
	switch (entry.kind) {
		case "pi.user":
			return { id: entry.id, kind: "user", text: clip(textOf(message?.content)), timestamp: message?.timestamp as number | undefined };
		case "pi.assistant": {
			const parts = assistantParts(message as { content?: Block[] });
			return {
				id: entry.id,
				kind: "assistant",
				text: parts.text,
				thinking: clip(parts.thinking),
				toolCalls: parts.toolCalls,
				model: message ? `${message.provider}/${message.model}` : undefined,
				stopReason: message?.stopReason as string | undefined,
				error: message?.errorMessage as string | undefined,
				timestamp: message?.timestamp as number | undefined,
			};
		}
		case "pi.tool-result": {
			const toolName = String(message?.toolName ?? "");
			const isError = message?.isError === true;
			const text = textOf(message?.content);
			return {
				id: entry.id,
				kind: "toolResult",
				callId: String(message?.toolCallId ?? ""),
				toolName,
				text: clip(text),
				isError,
				timestamp: message?.timestamp as number | undefined,
				surface: (message?.details as { surface?: DisplaySurface } | undefined)?.surface,
				data: cardData(toolName, isError, text, message?.details),
			};
		}
		case "app.input": {
			const data = entry.data as InputData | undefined;
			return {
				id: entry.id,
				kind: "user",
				text: clip(data?.attachments === undefined && data?.skill === undefined ? textOf(message?.content) : (data.text ?? "")),
				timestamp: message?.timestamp as number | undefined,
				origin: data?.origin,
				attachments: data?.attachments,
				skill: data?.skill,
			};
		}
		case "pi.compaction":
			return { id: entry.id, kind: "notice", text: "Earlier messages were summarized" };
		case "pi.reset":
			return { id: entry.id, kind: "notice", text: "New context" };
		default:
			// pi.system and bookkeeping entries are not shown.
			return undefined;
	}
}

type LiveDoc = {
	run?: unknown;
	generation?: { attempt: number; message?: { content?: Block[] }; retry?: { at: number; error: string } };
	tools?: { callId: string; name: string; status: string; output?: string }[];
	compactions?: unknown[];
	compactionFailure?: { error: string };
};

export function displayLive(live: LiveDoc | undefined): DisplayLive {
	const generation = live?.generation;
	return {
		busy: live?.run !== undefined,
		generation:
			generation === undefined
				? undefined
				: { ...assistantParts(generation.message), attempt: generation.attempt, retry: generation.retry },
		tools: (live?.tools ?? []).map((t) => ({
			callId: t.callId,
			name: t.name,
			status: t.status,
			output: t.output === undefined ? undefined : clip(t.output),
		})),
		compacting: (live?.compactions?.length ?? 0) > 0,
		compactionError: live?.compactionFailure?.error,
	};
}

type UsageDoc = { models?: Record<string, { input?: number; output?: number; cost?: { total?: number } }> };

export function displayUsage(usage: UsageDoc | undefined): DisplayFrame["usage"] {
	const total = { input: 0, output: 0, cost: 0 };
	for (const bucket of Object.values(usage?.models ?? {})) {
		total.input += bucket.input ?? 0;
		total.output += bucket.output ?? 0;
		total.cost += bucket.cost?.total ?? 0;
	}
	return total;
}

/**
 * A queued message's typed text; with attachments, the text alone, or what is attached when there is none. A skill run
 * starts with the skill's "/" name.
 */
function queuedText(item: Extract<InboxState["items"][number], { content: unknown }>): string {
	const data = (item.entry as { data?: InputData } | undefined)?.data;
	if (data?.attachments === undefined && data?.skill === undefined) return textOf(item.content);
	const typed = [data.skill === undefined ? "" : `/${data.skill}`, data.text?.trim() ?? ""].filter((part) => part !== "").join(" ");
	if (data.attachments === undefined) return typed;
	const summary = attachmentSummary(data.attachments);
	return typed === "" ? `📎 ${summary}` : `${typed} (📎 ${summary})`;
}

/** Remembers which entries a watcher already sent, so the next frame carries only new ones. */
export class FrameBuilder {
	#sent: number[] = [];
	#cache = new Map<number, DisplayItem | undefined>();

	constructor(readonly conversationId: number) {}

	frame(value: { entries: readonly EntryRecord[]; docs: Readonly<Record<string, unknown>> }): DisplayFrame {
		const ids = value.entries.map((e) => e.id);
		const sent = this.#sent;
		const appends =
			sent.length > 0 && ids.length >= sent.length && ids[0] === sent[0] && ids[sent.length - 1] === sent[sent.length - 1];
		const fresh = appends ? value.entries.slice(sent.length) : value.entries;
		const items: DisplayItem[] = [];
		for (const entry of fresh) {
			if (!this.#cache.has(entry.id)) this.#cache.set(entry.id, displayItem(entry));
			const item = this.#cache.get(entry.id);
			if (item !== undefined) items.push(item);
		}
		this.#sent = ids;
		const docs = value.docs;
		const agent = docs["pi.agent"] as { model?: { provider: string; modelId: string }; thinkingLevel?: ModelThinkingLevel } | undefined;
		const inbox = docs["pi.inbox"] as InboxState | undefined;
		return {
			conversationId: this.conversationId,
			reset: !appends,
			items,
			live: displayLive(docs["pi.live"] as LiveDoc | undefined),
			queue: (inbox?.items ?? []).flatMap((item) =>
				item.mode === "write" ? [] : [{ id: item.id as number, text: queuedText(item), mode: item.mode }],
			),
			model: agent?.model,
			thinkingLevel: agent?.thinkingLevel ?? "off",
			usage: displayUsage(docs["pi.usage"] as UsageDoc | undefined),
		};
	}
}
