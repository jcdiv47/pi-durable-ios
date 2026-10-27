// Turns a conversation's structural view (`viewState()`) into the small display model the SwiftUI
// transcript renders. Entries are immutable, so frames carry only the entries appended since the last
// frame, plus the whole live state (streamed partial, running tools), which is small.

import type { EntryRecord } from "@earendil-works/pi-durable";

export type DisplayToolCall = { id: string; name: string; arguments: string };

export type DisplayItem =
	| { id: number; kind: "user"; text: string; timestamp?: number }
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
	| { id: number; kind: "toolResult"; callId: string; toolName: string; text: string; isError: boolean }
	| { id: number; kind: "notice"; text: string };

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
	queued: number;
	model?: { provider: string; modelId: string };
	usage: { input: number; output: number; cost: number };
};

/** Display text is bounded; tool results such as a month of calendar events can be long. */
const MAX_TEXT = 6000;

function clip(text: string): string {
	return text.length > MAX_TEXT ? `${text.slice(0, MAX_TEXT)}\n… (${text.length - MAX_TEXT} more characters)` : text;
}

type Block = { type: string; text?: string; thinking?: string; id?: string; name?: string; arguments?: unknown };

function textOf(content: unknown): string {
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
		case "pi.tool-result":
			return {
				id: entry.id,
				kind: "toolResult",
				callId: String(message?.toolCallId ?? ""),
				toolName: String(message?.toolName ?? ""),
				text: clip(textOf(message?.content)),
				isError: message?.isError === true,
			};
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
		const agent = docs["pi.agent"] as { model?: { provider: string; modelId: string } } | undefined;
		const inbox = docs["pi.inbox"] as { items?: { mode: string }[] } | undefined;
		return {
			conversationId: this.conversationId,
			reset: !appends,
			items,
			live: displayLive(docs["pi.live"] as LiveDoc | undefined),
			queued: (inbox?.items ?? []).filter((item) => item.mode !== "write").length,
			model: agent?.model,
			usage: displayUsage(docs["pi.usage"] as UsageDoc | undefined),
		};
	}
}
