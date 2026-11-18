// Web cards: UI the agent writes as HTML, shown in the chat. The app draws each in a sandboxed web view with no network
// (no fetch, no external images, scripts or styles), with Pi's web components (`<pi-chart>`, `<pi-table>`, `<pi-form>`…)
// and design tokens already loaded. What the user does in a card comes back as a message: `pi.submit(value)` or
// `pi.prompt(text)`, sent by Swift with a request ID derived from the card and the value, so a repeated tap is one
// message (`Chat.cardInput`).
//
// Cards live in a rewindable conversation document, like surfaces: a fork sees them as of its fork point, a rerun after
// a crash finds the card its task made, and the tool result's details carry the HTML the transcript draws.

import type { JsonValue } from "@earendil-works/chord";
import { obj, opt, str } from "@earendil-works/pi-schema";
import { defineDoc, defineExtension, defineTool, section, type ToolExecutionApi } from "@earendil-works/pi-durable";

export type WebCardRecord = {
	id: string;
	version: number;
	title: string;
	html: string;
	createdAt: number;
	updatedAt: number;
	/** The tool task that created it, so a rerun after a crash finds it instead of creating another. */
	createdBy: number;
	/** Tool tasks whose updates are applied (the newest few), so a rerun does not count its update twice. */
	updatedBy: number[];
};

export const WebCardsDoc = defineDoc<{ items: Record<string, WebCardRecord>; next: number }>({
	kind: "ui.webcards",
	version: 1,
	scope: "conversation",
	history: "rewindable",
	fork: "asOf",
	initial: () => ({ items: {}, next: 1 }),
	checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 10,
});

/** What the transcript draws under the call: the card's HTML at this version. */
export type DisplayWebCard = { conversationId: number; id: string; version: number; title: string; html: string };

/** A card's HTML may be this long; larger ones should move data into fewer, denser components. */
export const MAX_HTML = 200_000;

function cardDetails(api: ToolExecutionApi, card: WebCardRecord): JsonValue {
	return { webCard: { conversationId: api.conversationId, id: card.id, version: card.version, title: card.title, html: card.html } };
}

/**
 * Things in the HTML the sandbox will block, said back to the model so it fixes them instead of assuming they work.
 * Not a security check: the web view's CSP and content rules are.
 */
export function lint(html: string): string[] {
	const warnings: string[] = [];
	if (/<script[^>]+\bsrc\s*=/i.test(html)) warnings.push("External scripts are blocked; inline the script.");
	if (/<link[^>]+rel\s*=\s*["']?stylesheet/i.test(html)) warnings.push("External stylesheets are blocked; use a <style> element.");
	if (/\b(src|href)\s*=\s*["']?\s*(https?:)?\/\//i.test(html.replace(/<a\b[^>]*>/gi, "").replace(/<pi-button\b[^>]*>/gi, "")))
		warnings.push("Remote images, fonts and media are blocked; use inline SVG or data: URLs.");
	if (/\bfetch\s*\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon/.test(html)) warnings.push("The network is blocked: fetch, XHR and sockets fail.");
	if (/\b(localStorage|sessionStorage|indexedDB|document\.cookie)\b/.test(html)) warnings.push("Storage is unavailable; keep state in variables.");
	if (/<iframe\b/i.test(html)) warnings.push("Frames are blocked.");
	if (/(^|[^.\w])(alert|confirm|prompt)\s*\(/.test(html)) warnings.push("alert, confirm and prompt do nothing; use pi.prompt or show text.");
	return warnings;
}

function shown(card: WebCardRecord, warnings: string[]) {
	return {
		output: [
			{
				type: "text" as const,
				text: JSON.stringify(
					{
						id: card.id,
						version: card.version,
						shown: true,
						bytes: card.html.length,
						...(warnings.length === 0 ? {} : { warnings }),
						note: "The user sees the card now. Their submissions arrive as new messages; don't repeat the card's content in text.",
					},
					null,
					1,
				),
			},
		],
	};
}

function failure(message: string) {
	return { output: [{ type: "text" as const, text: message }], isError: true };
}

const showUI = defineTool({
	name: "show_ui",
	description:
		"Show a UI card in this chat, written as HTML: an interactive answer (a chart, a comparison table, a form, a picker, a plan). " +
		"Pi's web components and design tokens are loaded; plain HTML, <style> and inline <script> work too. No network. " +
		"Returns the card's id for update_ui.",
	parameters: obj({
		title: str({ description: "A short title, shown above the card and in the transcript" }),
		html: str({ description: "The card's body HTML (no <html> or <head>)" }),
	}),
	replay: "safe",
	execute: async (args, api, context) => {
		if (args.html.length > MAX_HTML) return failure(`The HTML is ${args.html.length} characters; keep it under ${MAX_HTML}.`);
		const now = Date.now();
		const card = await api.commit(async (tx) => {
			const doc = await tx.doc(WebCardsDoc, api.conversationId);
			const existing = Object.values(doc.items).find((item) => item.createdBy === api.taskId);
			if (existing !== undefined) return structuredClone(existing) as WebCardRecord;
			const id = `w${doc.next}`;
			doc.next += 1;
			const created: WebCardRecord = { id, version: 1, title: args.title, html: args.html, createdAt: now, updatedAt: now, createdBy: api.taskId, updatedBy: [] };
			doc.items[id] = created;
			return structuredClone(created);
		}, context);
		return { ...shown(card, lint(card.html)), details: cardDetails(api, card) };
	},
});

const updateUI = defineTool({
	name: "update_ui",
	description:
		"Replace a card's HTML (and title, if given) with a new version, e.g. after the user submitted it or the data changed. " +
		"The chat shows the new version under this call; the old one points to it.",
	parameters: obj({
		id: str({ description: "The card's id, from show_ui" }),
		html: str({ description: "The card's new body HTML" }),
		title: opt(str()),
	}),
	replay: "safe",
	execute: async (args, api, context) => {
		if (args.html.length > MAX_HTML) return failure(`The HTML is ${args.html.length} characters; keep it under ${MAX_HTML}.`);
		const card = await api.commit(async (tx) => {
			const doc = await tx.doc(WebCardsDoc, api.conversationId);
			const item = doc.items[args.id];
			if (item === undefined) return undefined;
			if (!item.updatedBy.includes(api.taskId)) {
				item.version += 1;
				item.html = args.html;
				if (args.title !== undefined && args.title.trim() !== "") item.title = args.title;
				item.updatedAt = Date.now();
				item.updatedBy = [...item.updatedBy, api.taskId].slice(-8);
			}
			return structuredClone(item) as WebCardRecord;
		}, context);
		if (card === undefined) return failure(`No card ${args.id} in this conversation.`);
		return { ...shown(card, lint(card.html)), details: cardDetails(api, card) };
	},
});

const webUISection = section("webui", () =>
	[
		"You can show UI cards in this chat with show_ui: HTML drawn natively styled, for answers that read better as UI than as text:",
		"charts of numbers, comparison tables, forms and pickers that ask for several things at once, plans and checklists. Prefer Markdown for plain prose.",
		"Components (attributes marked JSON take JSON):",
		'- <pi-card title subtitle kicker> any content </pi-card>; <pi-stats> holding <pi-stat label value delta trend="up|down">; <pi-badge tone="accent|success|warning|danger">',
		'- <pi-chart type="line|bar|area" height="180" unit="" data=\'{"labels":[...],"series":[{"name":"","values":[...]}]}\'> (JSON)',
		"- <pi-table data='[{...}]'> (JSON, sortable) or columns='[...]' rows='[[...]]'; <pi-list items='[{\"title\":\"\",\"subtitle\":\"\",\"trailing\":\"\"}]'> (JSON)",
		'- <pi-progress value="0.4" label>; <pi-tabs> holding <pi-tab label> panels </pi-tab>; <pi-code lang> text </pi-code>; <pi-diff> unified diff </pi-diff>',
		'- Inputs, inside <pi-form submit="Send"> (submits every named value at once): <pi-input name label placeholder type>,',
		"  <pi-choice name label options='[\"A\",\"B\"]' multiple> (JSON), <pi-slider name label min max step value unit>, <pi-date name label type=\"date|time|datetime-local\">,",
		"  <pi-toggle name label>. A single-choice <pi-choice> outside a form submits on tap.",
		'- <pi-button prompt="text to send">Label</pi-button> sends that text as the user; <pi-button href="https://…"> opens a link.',
		"Script API: pi.submit(value, label?) sends value (JSON) back as the user's answer, label is what the chat shows; pi.prompt(text); pi.openURL(url);",
		"pi.data holds your set_value values.",
		"Rules: no network, no external scripts, styles, images or fonts (inline SVG and data: URLs work), no storage. Light and dark follow the phone:",
		"use the CSS variables (--pi-surface, --pi-sunken, --pi-text, --pi-secondary, --pi-hairline, --pi-accent, --pi-success, --pi-warning, --pi-danger,",
		"--pi-radius-card) instead of fixed colors. Cards are about 360pt wide. Change a card with update_ui instead of showing it again.",
	].join("\n"),
);

export const WebUITools = defineExtension({
	name: "ui.web",
	sections: [webUISection],
	tools: [showUI, updateUI],
});

/** Tool names with what they do, for the approval settings screen. */
export const webUIToolInfo = WebUITools.tools!.map((tool) => ({ name: tool.name, description: tool.description }));

/** What the chat shows for a submitted value without a label: "Dates: Jun 3 – Jun 7 · Guests: 2", at most 200 characters. */
export function cardValueSummary(value: unknown): string {
	const scalar = (v: unknown): string =>
		v === null || v === undefined ? "—" : typeof v === "boolean" ? (v ? "Yes" : "No") : Array.isArray(v) ? v.map(scalar).join(", ") : typeof v === "object" ? JSON.stringify(v) : String(v);
	let text: string;
	if (value !== null && typeof value === "object" && !Array.isArray(value)) {
		const entries = Object.entries(value as Record<string, unknown>);
		text = entries.length === 0 ? "Submitted" : entries.map(([key, v]) => `${key[0]!.toUpperCase()}${key.slice(1)}: ${scalar(v)}`).join(" · ");
	} else {
		text = scalar(value);
	}
	return text.length > 200 ? `${text.slice(0, 199)}…` : text;
}
