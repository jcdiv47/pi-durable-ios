// A conversation as Markdown, for the share sheet (`Chat.exportMarkdown`) and the backup archive. What was said is
// whole; tool calls fold into <details> blocks with their arguments and results (results clipped as the transcript
// clips them); thinking is left out. Images are named, not embedded: the archive carries their files.

import type { DisplayAttachment } from "./attachments.ts";
import type { DisplayItem } from "./display.ts";

export type MarkdownMeta = {
	title: string;
	createdAt: number;
	model?: { provider: string; modelId: string };
	forkOf?: string;
	archivedAt?: number;
};

const pad = (n: number) => String(n).padStart(2, "0");

/** Local time as `2026-11-17 14:03`: JSC's Intl data is not something to count on. */
export function localTime(ms: number): string {
	const date = new Date(ms);
	return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/** A fence longer than any run of backticks in `text`, so code in a tool result cannot close it. */
function fenced(text: string, language = ""): string {
	const longest = Math.max(2, ...[...text.matchAll(/`+/g)].map((match) => match[0].length));
	const fence = "`".repeat(longest + 1);
	return `${fence}${language}\n${text.replace(/\n$/, "")}\n${fence}`;
}

function attachmentLine(attachment: DisplayAttachment): string {
	switch (attachment.kind) {
		case "image":
			return `- Image${attachment.name ? `: ${attachment.name}` : ""}${attachment.file ? ` (\`attachments/${attachment.file}\`)` : ""}`;
		case "text":
			return `- ${attachment.name ?? "Text"} (${attachment.length.toLocaleString()} characters)`;
		case "link":
			return `- [${(attachment.title ?? attachment.url).replace(/[[\]]/g, "")}](${attachment.url})`;
	}
}

function prettyArguments(json: string): string {
	try {
		return JSON.stringify(JSON.parse(json), null, 2);
	} catch {
		return json;
	}
}

function heading(who: string, timestamp: number | undefined): string {
	return timestamp === undefined ? `**${who}**` : `**${who}** · ${localTime(timestamp)}`;
}

export function conversationMarkdown(meta: MarkdownMeta, items: readonly DisplayItem[], exportedAt = Date.now()): string {
	const results = new Map<string, Extract<DisplayItem, { kind: "toolResult" }>>();
	for (const item of items) if (item.kind === "toolResult") results.set(item.callId, item);

	const about = [`Started ${localTime(meta.createdAt)}`];
	if (meta.model !== undefined) about.push(`model ${meta.model.provider}/${meta.model.modelId}`);
	if (meta.forkOf !== undefined) about.push(`forked from “${meta.forkOf}”`);
	if (meta.archivedAt !== undefined) about.push(`archived ${localTime(meta.archivedAt)}`);
	about.push(`exported from Pi ${localTime(exportedAt)}`);
	const header = `# ${meta.title.replace(/\n/g, " ")}\n\n*${about.join(" · ")}*`;
	const blocks: string[] = [];

	for (const item of items) {
		switch (item.kind) {
			case "user": {
				const who = item.voice !== undefined ? "You, through Talk to Pi" : item.origin !== undefined ? `You (${item.origin})` : "You";
				const parts = [heading(who, item.timestamp)];
				if (item.skill !== undefined) parts.push(`\`/${item.skill}\``);
				if (item.text.trim() !== "") parts.push(item.text.trim());
				if (item.attachments !== undefined && item.attachments.length > 0) parts.push(item.attachments.map(attachmentLine).join("\n"));
				blocks.push(parts.join("\n\n"));
				break;
			}
			case "assistant": {
				const parts = [heading("Pi", item.timestamp)];
				if (item.text.trim() !== "") parts.push(item.text.trim());
				for (const call of item.toolCalls) {
					const result = results.get(call.id);
					const body = [`Arguments:\n\n${fenced(prettyArguments(call.arguments), "json")}`];
					if (result !== undefined) body.push(`${result.isError ? "Error" : "Result"}:\n\n${fenced(result.text)}`);
					parts.push(`<details><summary>Tool: ${call.name}</summary>\n\n${body.join("\n\n")}\n\n</details>`);
				}
				if (item.stopReason === "error") parts.push(`*The run failed${item.error ? `: ${item.error}` : ""}*`);
				else if (item.stopReason === "aborted") parts.push("*Stopped*");
				if (parts.length > 1) blocks.push(parts.join("\n\n"));
				break;
			}
			case "voice":
				if (item.text.trim() !== "") blocks.push(`${heading(item.voice.role === "pi" ? "Pi (spoken)" : "You (spoken)", item.timestamp)}\n\n${item.text.trim()}`);
				break;
			case "notice":
				blocks.push(`*${item.text}*`);
				break;
			case "toolResult":
				// Shown with its call; a result whose call is gone (a compaction) is skipped.
				break;
		}
	}
	return `${[header, ...blocks].join("\n\n---\n\n")}\n`;
}
