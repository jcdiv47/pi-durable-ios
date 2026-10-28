// Context the user attaches to a message: from the composer (Photos, Paste, Files) or the share sheet. Swift
// prepares them (images downscaled to JPEG, file text read); this turns them into the user message's content and
// into what the transcript shows, which goes in the input entry's data so the bubble shows the typed text alone.

import type { ImageContent, TextContent } from "@earendil-works/pi-ai";

export type InputAttachment =
	/** `file`: the image's copy in the App Group's `attachments/`, for the transcript's thumbnail. */
	| { kind: "image"; data: string; mimeType: string; name?: string; file?: string }
	| { kind: "text"; text: string; name?: string }
	| { kind: "link"; url: string; title?: string };

export type DisplayAttachment =
	| { kind: "image"; name?: string; file?: string }
	| { kind: "text"; name?: string; preview: string; length: number }
	| { kind: "link"; url: string; title?: string };

/** What the input entry keeps besides the message: where it came from, the typed text and the attachments. */
export type InputData = { origin?: string; text?: string; attachments?: DisplayAttachment[] };

/** A shared PDF or web page can be long; the model gets this much of each. */
const MAX_TEXT = 100_000;

function attribute(value: string): string {
	return value.replace(/[&"<>\n]/g, (c) => (c === "&" ? "&amp;" : c === '"' ? "&quot;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : " "));
}

/** The typed text, then each attachment in order: text and links as tagged text, images as image blocks. */
export function inputContent(text: string, attachments: readonly InputAttachment[]): (TextContent | ImageContent)[] {
	const blocks: (TextContent | ImageContent)[] = [];
	if (text.trim() !== "") blocks.push({ type: "text", text });
	for (const attachment of attachments) {
		switch (attachment.kind) {
			case "image":
				blocks.push({ type: "image", data: attachment.data, mimeType: attachment.mimeType });
				break;
			case "text": {
				const name = attachment.name === undefined ? "" : ` name="${attribute(attachment.name)}"`;
				const cut = attachment.text.length > MAX_TEXT;
				const body = cut ? `${attachment.text.slice(0, MAX_TEXT)}\n… (${attachment.text.length - MAX_TEXT} more characters not shown)` : attachment.text;
				blocks.push({ type: "text", text: `<attachment kind="text"${name}>\n${body}\n</attachment>` });
				break;
			}
			case "link": {
				const title = attachment.title === undefined ? "" : ` title="${attribute(attachment.title)}"`;
				blocks.push({ type: "text", text: `<attachment kind="link"${title}>${attachment.url}</attachment>` });
				break;
			}
		}
	}
	return blocks;
}

export function displayAttachments(attachments: readonly InputAttachment[]): DisplayAttachment[] {
	return attachments.map((attachment) => {
		switch (attachment.kind) {
			case "image":
				return { kind: "image", name: attachment.name, file: attachment.file };
			case "text":
				return { kind: "text", name: attachment.name, preview: attachment.text.slice(0, 280), length: attachment.text.length };
			case "link":
				return { kind: "link", url: attachment.url, title: attachment.title };
		}
	});
}

/** A withdrawn message's attachments as the composer takes them back: an image by its file, without its data. */
export type EditableAttachment =
	| { kind: "image"; file: string; name?: string }
	| { kind: "text"; text: string; name?: string }
	| { kind: "link"; url: string; title?: string };

const cutNote = /\n… \(\d+ more characters not shown\)$/;

/**
 * The inverse of `inputContent` for a queued message: the blocks after the typed text are the attachments in order.
 * Texts come out of their tags (a text over `MAX_TEXT` comes back cut); an image whose file is unknown is dropped.
 */
export function editableAttachments(content: unknown, attachments: readonly DisplayAttachment[], text: string): EditableAttachment[] {
	const blocks = Array.isArray(content) ? (content as (TextContent | ImageContent)[]) : [];
	const parts = text.trim() === "" ? blocks : blocks.slice(1);
	const result: EditableAttachment[] = [];
	attachments.forEach((attachment, index) => {
		switch (attachment.kind) {
			case "image":
				if (attachment.file !== undefined) result.push({ kind: "image", file: attachment.file, name: attachment.name });
				break;
			case "text": {
				const block = parts[index];
				if (block?.type !== "text") break;
				const body = block.text.slice(block.text.indexOf("\n") + 1, block.text.lastIndexOf("\n</attachment>"));
				result.push({ kind: "text", text: body.replace(cutNote, ""), name: attachment.name });
				break;
			}
			case "link":
				result.push({ kind: "link", url: attachment.url, title: attachment.title });
				break;
		}
	});
	return result;
}

/** The image files a message's display form points at, so they are not swept while it is shown or queued. */
export function attachmentFiles(data: unknown): string[] {
	const attachments = (data as InputData | undefined)?.attachments ?? [];
	return attachments.flatMap((attachment) => (attachment.kind === "image" && attachment.file !== undefined ? [attachment.file] : []));
}

/** "2 images, 1 link": a queued message or a title without typed text. */
export function attachmentSummary(attachments: readonly { kind: string }[]): string {
	const counts = new Map<string, number>();
	for (const { kind } of attachments) counts.set(kind, (counts.get(kind) ?? 0) + 1);
	const nouns: Record<string, [string, string]> = { image: ["image", "images"], text: ["text", "texts"], link: ["link", "links"] };
	return [...counts]
		.map(([kind, count]) => `${count} ${(nouns[kind] ?? [kind, kind])[count === 1 ? 0 : 1]}`)
		.join(", ");
}

/** A conversation title when the message has no text: the first link's title or a text's name, else the summary. */
export function attachmentTitle(attachments: readonly InputAttachment[]): string | undefined {
	for (const attachment of attachments) {
		if (attachment.kind === "link" && attachment.title) return attachment.title;
		if (attachment.kind === "text" && attachment.name) return attachment.name;
	}
	if (attachments.length === 0) return undefined;
	return attachments.every((a) => a.kind === "image") ? (attachments.length === 1 ? "Image" : `${attachments.length} images`) : attachmentSummary(attachments);
}
