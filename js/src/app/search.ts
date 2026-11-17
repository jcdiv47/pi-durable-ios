// Full-text search through what was said in the conversations. The matching lives here, in JS, rather than in the
// list's view: the conversation list calls it (`Chat.search`, `PiRuntime.searchConversations`), and a search tool for
// the agent can call the same function later and get the same hits.

import type { DisplayItem } from "./display.ts";

/** A message with the search text in it. The snippet is in three parts so whoever shows it can mark the match. */
export type SearchHit = {
	conversationId: number;
	/** The conversation's title when the search ran. */
	title: string;
	/** The message's entry: the transcript's row. */
	messageId: number;
	role: "user" | "pi";
	timestamp?: number;
	before: string;
	matched: string;
	after: string;
};

export type SearchOptions = {
	/** The most hits from one conversation, its newest first. Default 3. */
	perConversation?: number;
	/** The most hits in all. Default 200. */
	limit?: number;
};

/** A message ready to search: its text, and the text folded for matching with each folded unit's place in it. */
export type SearchableMessage = {
	id: number;
	role: "user" | "pi";
	text: string;
	timestamp?: number;
	folded: string;
	starts: number[];
};

/**
 * `text` without case or diacritics ("Lisbón" and "lisbon" are the same), and for each UTF-16 unit of the result the
 * index in `text` of the character it came from.
 */
export function fold(text: string): { folded: string; starts: number[] } {
	let folded = "";
	const starts: number[] = [];
	for (let index = 0; index < text.length; ) {
		const code = text.codePointAt(index)!;
		const length = code > 0xffff ? 2 : 1;
		const part =
			code < 0x80
				? text[index]!.toLowerCase()
				: text
						.slice(index, index + length)
						.normalize("NFD")
						.replace(/\p{M}+/gu, "")
						.toLowerCase();
		folded += part;
		for (let unit = 0; unit < part.length; unit++) starts.push(index);
		index += length;
	}
	return { folded, starts };
}

/**
 * What was said in a transcript: the user's messages, Pi's answers and the lines spoken in Talk to Pi, oldest first,
 * each under its entry's ID. No thinking, no tool calls or results.
 */
export function searchable(items: readonly DisplayItem[]): SearchableMessage[] {
	const messages: SearchableMessage[] = [];
	for (const item of items) {
		if (item.kind !== "user" && item.kind !== "assistant" && item.kind !== "voice") continue;
		if (item.kind === "assistant" && item.noReply) continue;
		const text = item.text.trim();
		if (text === "") continue;
		const role = item.kind === "assistant" || (item.kind === "voice" && item.voice.role === "pi") ? "pi" : "user";
		messages.push({ id: item.id, role, text, ...(item.timestamp === undefined ? {} : { timestamp: item.timestamp }), ...fold(text) });
	}
	return messages;
}

const line = (text: string) => text.replace(/\s+/g, " ");

/**
 * The text around a match, on one line: from a word start a little before it, so the match is near the snippet's
 * start, to some way after it.
 */
export function snippet(text: string, from: number, to: number): { before: string; matched: string; after: string } {
	let start = Math.max(0, from - 28);
	if (start > 0) {
		const space = text.slice(start, from).search(/\s/);
		if (space >= 0) start += space + 1;
		// Not inside a surrogate pair.
		else if ((text.charCodeAt(start) & 0xfc00) === 0xdc00) start += 1;
	}
	let end = Math.min(text.length, to + 160);
	if (end < text.length && (text.charCodeAt(end - 1) & 0xfc00) === 0xd800) end -= 1;
	return {
		before: (start > 0 ? "…" : "") + line(text.slice(start, from)),
		matched: line(text.slice(from, to)),
		after: line(text.slice(to, end)) + (end < text.length ? "…" : ""),
	};
}

/** The newest messages with `needle` (already folded) in them, newest first, at most `limit`. */
export function hitsIn(messages: readonly SearchableMessage[], needle: string, limit: number): Omit<SearchHit, "conversationId" | "title">[] {
	const hits: Omit<SearchHit, "conversationId" | "title">[] = [];
	for (let index = messages.length - 1; index >= 0 && hits.length < limit; index--) {
		const message = messages[index]!;
		const at = message.folded.indexOf(needle);
		if (at < 0) continue;
		const from = message.starts[at]!;
		const to = message.starts[at + needle.length] ?? message.text.length;
		hits.push({
			messageId: message.id,
			role: message.role,
			...(message.timestamp === undefined ? {} : { timestamp: message.timestamp }),
			...snippet(message.text, from, to),
		});
	}
	return hits;
}
