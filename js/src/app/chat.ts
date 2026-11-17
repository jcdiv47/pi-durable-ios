// The chat app's operations on the Harness, called from Swift through `PiRuntime.*`. Swift renders what
// these emit: `frame` events for watched conversations, `conversations` when the list changes, and
// `approvals` when a tool call waits for the user.

import type { ModelThinkingLevel } from "@earendil-works/pi-ai";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { JsonValue } from "@earendil-works/chord";
import {
	AssistantEntry,
	type Conversation,
	type ConversationWatch,
	defineDoc,
	type EntryRecord,
	type Extension,
	type Harness,
	InboxDoc,
	type InboxState,
	LiveDoc,
	type Submission,
	type TranscriptView,
} from "@earendil-works/pi-durable";
import { type Approvals, type Decision, defaultPolicies, type ToolPolicy } from "./approvals.ts";
import {
	attachmentFiles,
	attachmentTitle,
	displayAttachments,
	type EditableAttachment,
	editableAttachments,
	type InputAttachment,
	type InputData,
	inputContent,
} from "./attachments.ts";
import { type DisplayItem, displayItem, type DisplaySurface, FrameBuilder, textOf } from "./display.ts";
import { conversationMarkdown } from "./export.ts";
import { answerText, isNoReply, noReplyText, OriginInput, SchedulesDoc } from "./schedule.ts";
import { fold, hitsIn, searchable, type SearchableMessage, type SearchHit, type SearchOptions } from "./search.ts";
import { readSkill, skillContent } from "./skills.ts";
import { type Spend, spendBetween, spendOf, type SpendTotals } from "./usage.ts";
import { VoiceEntry, type VoiceLine, type VoiceLineInput } from "./voice.ts";
import { PublishedDoc, SurfacesDoc, ValuesDoc } from "./surfaces.ts";
import { complete, entriesOf, readView, transcriptOf } from "./view.ts";
import { hostCall } from "../host/hostcall.ts";

const context = BACKGROUND_CONTEXT;

export type ConversationMeta = {
	id: number;
	title: string;
	createdAt: number;
	updatedAt: number;
	/** Set on forks: the conversation and entry they branched from. */
	forkOf?: { conversationId: number; entryId: number };
	/** Set while the conversation is archived: out of the list, shown in Settings › Archived Conversations. */
	archivedAt?: number;
};

/**
 * Every conversation, archived ones included, newest activity first when read. `deleted`: conversations the user deleted.
 * Pi has no way to remove a conversation's entries, so a deleted one leaves the index and nothing opens it again: no list,
 * search, entry point or sweep sees it, and its attachment images and voice recordings go at the next sweep.
 */
export const ConversationIndex = defineDoc<{ items: ConversationMeta[]; deleted?: number[] }>({
	kind: "app.conversations",
	version: 1,
	scope: "session",
	initial: () => ({ items: [] }),
	checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 50,
});

/**
 * Requests from outside the chat (Siri, Shortcuts, widget buttons, notification actions), by request ID: the
 * conversation a request started, so a retried intent finds it, and whether a direct action already ran. The
 * newest 500 are kept.
 */
export const RequestsDoc = defineDoc<{ items: Record<string, { conversationId?: number; at: number }> }>({
	kind: "app.requests",
	version: 1,
	scope: "session",
	initial: () => ({ items: {} }),
	checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 50,
});

const keptRequests = 500;

function trimRequests(items: Record<string, { at: number }>): void {
	const keys = Object.keys(items);
	if (keys.length <= keptRequests) return;
	keys.sort((a, b) => items[a]!.at - items[b]!.at);
	for (const key of keys.slice(0, keys.length - keptRequests)) delete items[key];
}

/** An input from outside the chat: `origin` labels it in the transcript ("Siri", "Widget: Morning"). */
export type OutsideInput = {
	text: string;
	requestId: string;
	origin: string;
	/** Omitted: a new conversation, titled from the text. */
	conversationId?: number;
	/** How long to wait for the answer; 0 returns once the input is admitted. */
	waitMs: number;
	/** Screenshots, text and links from the share sheet. */
	attachments?: InputAttachment[];
	/** The Talk to Pi session that handed this request over. */
	voice?: string;
	model: { provider: string; modelId: string };
};

export type OutsideAnswer = {
	conversationId: number;
	/** `running` when the answer did not come within `waitMs`. */
	status: "done" | "running" | "unanswered";
	text?: string;
	/** The newest card the run made or changed, for a Siri snippet. */
	surface?: DisplaySurface;
};

/** A widget button's effect, resolved by PiUI from the published spec (`SurfaceAction` in Swift). */
export type WidgetAction =
	| { kind: "prompt"; prompt: string; title: string }
	| { kind: "set"; key: string; value: JsonValue }
	| { kind: "toggle"; key: string; index: number };

const untitled = "New conversation";

function titleFrom(text: string): string {
	const line = text.trim().split("\n")[0] ?? "";
	return line.length > 60 ? `${line.slice(0, 57)}…` : line || untitled;
}

/** Settings › Apple Intelligence. */
export const intelligenceSettings = { titles: false };

export class Chat {
	readonly #watches = new Map<number, ConversationWatch>();
	/** Messages read for `search`, by conversation, with the newest entry they were read at. */
	readonly #searched = new Map<number, { head: number; messages: Promise<readonly SearchableMessage[]> }>();
	/** Answers' spend read for `spending`, by conversation, with the newest entry they were read at. */
	readonly #spent = new Map<number, { head: number; spend: Promise<readonly Spend[]> }>();

	constructor(
		private readonly harness: Harness,
		private readonly approvals: Approvals,
		private readonly extensions: readonly Extension[],
		private readonly emit: (event: Record<string, unknown>) => void,
		/** The nearest thinking level a model supports (`ModelSetup.clampThinking`). */
		private readonly clampThinking: (model: { provider: string; modelId: string }, level: ModelThinkingLevel) => ModelThinkingLevel = (_, level) => level,
	) {}

	async #all(): Promise<ConversationMeta[]> {
		const index = await this.harness.snapshot(ConversationIndex, context);
		return [...(index?.items ?? [])].sort((a, b) => b.updatedAt - a.updatedAt);
	}

	/** The conversations the list shows: all but the archived ones, newest activity first. */
	async conversations(): Promise<ConversationMeta[]> {
		return (await this.#all()).filter((meta) => meta.archivedAt === undefined);
	}

	/** Archived conversations, most recently archived first. */
	async archivedConversations(): Promise<ConversationMeta[]> {
		return (await this.#all()).filter((meta) => meta.archivedAt !== undefined).sort((a, b) => b.archivedAt! - a.archivedAt!);
	}

	async #changed(): Promise<void> {
		this.emit({ type: "conversations", items: await this.conversations(), archived: await this.archivedConversations() });
	}

	/**
	 * `requestId`: an outside request that starts this conversation, recorded in the same commit. `thinkingLevel`: the
	 * default effort from Settings, clamped to the model; without it Pi asks for no thinking. A conversation keeps the
	 * model and effort it starts with.
	 */
	async create(model: { provider: string; modelId: string }, requestId?: string, thinkingLevel?: ModelThinkingLevel): Promise<ConversationMeta> {
		const now = Date.now();
		let meta: ConversationMeta | undefined;
		await this.harness.createConversation(
			{
				ownership: { kind: "ownerless" },
				agent: {
					model,
					extensions: [...this.extensions],
					...(thinkingLevel === undefined ? {} : { thinkingLevel: this.clampThinking(model, thinkingLevel) }),
				},
				init: async (tx, id) => {
					meta = { id, title: untitled, createdAt: now, updatedAt: now };
					(await tx.doc(ConversationIndex)).items.push(meta);
					if (requestId !== undefined) {
						const requests = await tx.doc(RequestsDoc);
						requests.items[requestId] = { conversationId: id, at: now };
						trimRequests(requests.items);
					}
				},
			},
			context,
		);
		await this.#changed();
		return meta!;
	}

	async #conversation(id: number): Promise<Conversation> {
		if ((await this.harness.snapshot(ConversationIndex, context))?.deleted?.includes(id)) throw new Error(`Conversation ${id} was deleted`);
		const conversation = await this.harness.conversation(id as never, context);
		if (conversation === undefined) throw new Error(`No conversation ${id}`);
		return conversation;
	}

	/** Starts `frame` events for one conversation; the first frame holds the whole transcript. */
	async watch(id: number): Promise<void> {
		this.unwatch(id);
		const conversation = await this.#conversation(id);
		const transcript = transcriptOf(conversation);
		const watch = await conversation.watch(context);
		this.#watches.set(id, watch);
		const builder = new FrameBuilder(id);
		const send = (view: TranscriptView) => {
			if (this.#watches.get(id) !== watch) return;
			this.emit({ type: "frame", frame: builder.frame({ entries: entriesOf(view), docs: view.docs }) });
		};
		// The view's window holds the newest entries only; the transcript pages in the rest.
		send(await complete(transcript, transcript.merge(watch.value), context));
		if (this.#watches.get(id) !== watch) return;
		watch.start(async (call) => {
			if (call.kind === "value") send(await complete(transcript, transcript.merge(call.value), context));
		});
	}

	/**
	 * Full-text search through what was said in the listed conversations (search.ts): the phrase, whatever its case or
	 * accents, in the user's messages, Pi's answers and spoken lines. Conversations newest first, and within one its
	 * newest matching messages first. The conversation list shows the hits; a search tool for the agent would call this too.
	 */
	async search(query: string, options: SearchOptions = {}): Promise<SearchHit[]> {
		const needle = fold(query.trim()).folded;
		if (needle === "") return [];
		const limit = options.limit ?? 200;
		const hits: SearchHit[] = [];
		for (const meta of await this.conversations()) {
			let messages: readonly SearchableMessage[];
			try {
				messages = await this.#searchable(meta.id);
			} catch {
				continue;
			}
			for (const hit of hitsIn(messages, needle, options.perConversation ?? 3)) hits.push({ conversationId: meta.id, title: meta.title, ...hit });
			if (hits.length >= limit) break;
		}
		return hits.slice(0, limit);
	}

	/**
	 * A conversation's messages ready to search, kept until it has a newer entry: reading a transcript is the slow part
	 * of a search, and the list searches again at each pause in typing.
	 */
	async #searchable(id: number): Promise<readonly SearchableMessage[]> {
		const conversation = await this.#conversation(id);
		const head = (await conversation.entries({ order: "descending" }, 1, undefined, context)).items[0]?.id ?? 0;
		const kept = this.#searched.get(id);
		if (kept?.head === head) return kept.messages;
		// The entries' whole text: the transcript's items cut long messages.
		const messages = readView(conversation, context).then((view) =>
			searchable(entriesOf(view).flatMap((entry) => displayItem(entry, true) ?? [])),
		);
		this.#searched.set(id, { head, messages });
		messages.catch(() => {
			if (this.#searched.get(id)?.messages === messages) this.#searched.delete(id);
		});
		return messages;
	}

	/**
	 * What the model answers asked in `[from, to)` (ms since 1970) cost, in all conversations, archived ones too. A
	 * deleted conversation's spend goes with it. Reads every transcript once; later calls reread only changed ones.
	 */
	async spending(from: number, to: number): Promise<SpendTotals> {
		const all: (readonly Spend[])[] = [];
		for (const meta of await this.#all()) {
			let spend: readonly Spend[];
			try {
				spend = await this.#spend(meta.id);
			} catch {
				continue;
			}
			// A fork's transcript holds its parent's answers up to the fork; they are the parent's spend.
			all.push(meta.forkOf === undefined ? spend : spend.filter((item) => item.at >= meta.createdAt));
		}
		return spendBetween(all, from, to);
	}

	async #spend(id: number): Promise<readonly Spend[]> {
		const conversation = await this.#conversation(id);
		const head = (await conversation.entries({ order: "descending" }, 1, undefined, context)).items[0]?.id ?? 0;
		const kept = this.#spent.get(id);
		if (kept?.head === head) return kept.spend;
		const spend = readView(conversation, context).then((view) => spendOf(entriesOf(view)));
		this.#spent.set(id, { head, spend });
		spend.catch(() => {
			if (this.#spent.get(id)?.spend === spend) this.#spent.delete(id);
		});
		return spend;
	}

	/** Spotlight's text for a conversation: its messages from the start, user and assistant text only, cut at `limit`. */
	async searchText(id: number, limit = 4000): Promise<string> {
		const frame = await this.transcript(id);
		let text = "";
		for (const item of frame.items) {
			if ((item.kind !== "user" && item.kind !== "assistant") || item.text.trim() === "") continue;
			text += `${item.text.trim()}\n`;
			if (text.length >= limit) break;
		}
		return text.slice(0, limit).trimEnd();
	}

	/** The whole transcript and live state once, as one frame (headless checks read this). */
	async transcript(id: number) {
		const view = await readView(await this.#conversation(id), context);
		return new FrameBuilder(id).frame({ entries: entriesOf(view), docs: view.docs });
	}

	unwatch(id: number): void {
		const watch = this.#watches.get(id);
		if (watch === undefined) return;
		this.#watches.delete(id);
		void watch.stop();
	}

	/**
	 * Admits a user message; while a run is going it queues as a follow-up. Never waits for the answer. With
	 * attachments, the model gets them after the text; the transcript shows the text and the attachments apart. With
	 * `skill` (the user ran it with "/"), the skill's body is read now and goes first, so the message keeps the skill as it
	 * was when sent, whatever happens to it later.
	 */
	async send(id: number, text: string, requestId: string, attachments: InputAttachment[] = [], skill?: string): Promise<{ submissionId: number }> {
		const submission = await this.#submit(id, text, requestId, undefined, attachments, skill);
		return { submissionId: submission.id };
	}

	async #submit(
		id: number,
		text: string,
		requestId: string,
		origin?: string,
		attachments: readonly InputAttachment[] = [],
		skill?: string,
		voice?: string,
	): Promise<Submission> {
		const conversation = await this.#conversation(id);
		const ran = skill === undefined ? undefined : await readSkill(skill);
		const data: InputData = {
			...(origin === undefined ? {} : { origin }),
			...(attachments.length === 0 && ran === undefined ? {} : { text }),
			...(attachments.length === 0 ? {} : { attachments: displayAttachments(attachments) }),
			...(ran === undefined ? {} : { skill: ran.name }),
			...(voice === undefined ? {} : { voice }),
		};
		const content =
			ran !== undefined
				? [...skillContent(ran, text), ...inputContent("", attachments)]
				: attachments.length === 0
					? text
					: inputContent(text, attachments);
		const submission = await conversation.submit(
			{
				type: "input",
				content,
				requestId,
				...(Object.keys(data).length === 0 ? {} : { entry: { kind: OriginInput, data } }),
			},
			context,
		);
		const now = Date.now();
		let firstTitle: string | undefined;
		await this.harness.commit(async (tx) => {
			const meta = (await tx.doc(ConversationIndex)).items.find((item) => item.id === id);
			if (meta === undefined) return;
			meta.updatedAt = now;
			if (meta.title !== untitled) return;
			if (text.trim() !== "") meta.title = firstTitle = titleFrom(text);
			else meta.title = ran !== undefined ? `/${ran.name}` : (attachmentTitle(attachments) ?? untitled);
		}, context);
		await this.#changed();
		if (firstTitle !== undefined && intelligenceSettings.titles && ran === undefined) void this.#writeTitle(id, text, firstTitle);
		return submission;
	}

	/**
	 * Replaces a first-line title with one the on-device model writes, unless the user renamed the conversation in the
	 * meantime. Best effort: Swift answers null when Apple Intelligence is unavailable, slow or refuses.
	 */
	async #writeTitle(id: number, text: string, fallback: string): Promise<void> {
		try {
			const title = await hostCall<string | null>("intelligence.title", { text });
			if (title === null || title === fallback) return;
			let changed = false;
			await this.harness.commit(async (tx) => {
				const meta = (await tx.doc(ConversationIndex)).items.find((item) => item.id === id);
				if (meta === undefined || meta.title !== fallback) return;
				meta.title = title;
				changed = true;
			}, context);
			if (changed) await this.#changed();
		} catch {
			// The first line stays.
		}
	}

	/**
	 * Siri, Shortcuts, widget buttons and notification replies: submits `text` and waits up to `waitMs` for the
	 * answer. Without a conversation it starts one; the request ID maps to it, so a retried intent finds the same
	 * conversation and the same submission instead of asking twice.
	 */
	async ask(input: OutsideInput): Promise<OutsideAnswer> {
		let id = input.conversationId;
		if (id === undefined) {
			id = (await this.harness.snapshot(RequestsDoc, context))?.items[input.requestId]?.conversationId;
			// A retried request whose conversation was deleted meanwhile starts a new one.
			if (id !== undefined && !(await this.#all()).some((meta) => meta.id === id)) id = undefined;
			id ??= (await this.create(input.model, input.requestId)).id;
		}
		const startedAt = Date.now();
		const submission = await this.#submit(id, input.text, input.requestId, input.origin, input.attachments, undefined, input.voice);
		if (input.waitMs <= 0) return { conversationId: id, status: "running" };
		let timer: ReturnType<typeof setTimeout> | undefined;
		const timeout = new Promise<undefined>((resolve) => {
			timer = setTimeout(() => resolve(undefined), input.waitMs);
		});
		const settled = await Promise.race([submission.wait(context), timeout]);
		clearTimeout(timer);
		if (settled === undefined) return { conversationId: id, status: "running" };
		if (settled.status !== "done" || settled.type !== "input") return { conversationId: id, status: "unanswered" };
		const conversation = await this.#conversation(id);
		const answer = await conversation.commit((tx) => tx.entry(AssistantEntry, settled.answer), context);
		const text = answerText(answer);
		const card = (await this.surfaces(id)).find((item) => item.updatedAt >= startedAt && item.spec.surface === "card");
		return {
			conversationId: id,
			status: "done",
			// "Run now" on a schedule that found nothing to tell.
			text: isNoReply(text) ? noReplyText : text,
			surface: card === undefined ? undefined : { conversationId: id, id: card.id, version: card.version, spec: card.spec },
		};
	}

	/** A widget button (`RunWidgetAction`): a prompt to the surface's conversation, or a direct `$doc` change. */
	async widgetAction(publishedId: string, action: WidgetAction, requestId: string, model: OutsideInput["model"]): Promise<OutsideAnswer | { done: boolean }> {
		const entry = ((await this.harness.snapshot(PublishedDoc, context))?.items ?? []).find((item) => item.publishedId === publishedId);
		if (entry === undefined) throw new Error(`No published surface ${publishedId}`);
		if (action.kind === "prompt") {
			return this.ask({ text: action.prompt, requestId, origin: `Widget: ${entry.title} › ${action.title}`, conversationId: entry.conversationId, waitMs: 0, model });
		}
		const values = await this.harness.commit(async (tx) => {
			const requests = await tx.doc(RequestsDoc);
			// A repeated request (a double tap on the same widget timeline entry) changes nothing again.
			if (requests.items[requestId] !== undefined) return undefined;
			requests.items[requestId] = { at: Date.now() };
			trimRequests(requests.items);
			const doc = await tx.doc(ValuesDoc);
			if (action.kind === "set") {
				doc.values[action.key] = action.value;
			} else {
				const list = doc.values[action.key];
				const item = Array.isArray(list) ? list[action.index] : undefined;
				if (item !== null && typeof item === "object" && !Array.isArray(item)) item.done = item.done !== true;
			}
			return structuredClone(doc.values) as Record<string, JsonValue>;
		}, context);
		if (values !== undefined) await hostCall("ui.values", { values });
		return { done: values !== undefined };
	}

	/** Every scheduled task, soonest first. */
	async schedules() {
		const items = (await this.harness.snapshot(SchedulesDoc, context))?.items ?? [];
		return [...items].sort((a, b) => (a.nextAt ?? Infinity) - (b.nextAt ?? Infinity));
	}

	/** `RunPiTask`: one run of a schedule now, in its conversation; its timetable stays as it is. */
	async runSchedule(name: string, requestId: string, waitMs: number, model: OutsideInput["model"]): Promise<OutsideAnswer> {
		const matches = (await this.schedules()).filter((item) => item.name.toLowerCase() === name.trim().toLowerCase());
		const entry = matches.sort((a, b) => b.createdAt - a.createdAt)[0];
		if (entry === undefined) throw new Error(`No scheduled task named ${name}`);
		return this.ask({
			text: `[Scheduled task "${entry.name}"] ${entry.prompt}`,
			requestId,
			origin: `Run now: ${entry.name}`,
			conversationId: entry.conversationId,
			waitMs,
			model,
		});
	}

	async cancelSchedule(taskId: number): Promise<void> {
		await this.harness.abortTask(taskId as never, context);
	}

	/** Conversations created before an extension existed get it added, so their agent sees its tools. */
	async upgrade(): Promise<void> {
		for (const meta of await this.#all()) {
			const conversation = await this.harness.conversation(meta.id as never, context);
			if (conversation === undefined) continue;
			const selected = new Set((await conversation.agent(context)).extensions.map((extension) => extension.name));
			const missing = this.extensions.filter((extension) => !selected.has(extension.name));
			if (missing.length > 0) await conversation.configure({ extensions: { add: missing } }, context);
		}
	}

	/** Stops the run and withdraws queued messages; resolves once the conversation is idle. */
	async abort(id: number): Promise<void> {
		await (await this.#conversation(id)).abort(context);
	}

	/** Withdraws one queued message; false when a boundary already placed it. */
	async withdraw(id: number, submissionId: number): Promise<boolean> {
		return (await this.harness.abortSubmission(submissionId as never, context, id as never)) === "aborted";
	}

	/**
	 * Withdraws a queued message to edit it: its typed text, attachments and skill as the composer takes them, or null
	 * when a boundary already placed it.
	 */
	async takeBack(id: number, submissionId: number): Promise<{ text: string; attachments: EditableAttachment[]; skill?: string } | null> {
		const inbox = await this.harness.snapshot(InboxDoc, id as never, context);
		const item = inbox?.items.find((candidate) => candidate.id === submissionId);
		if (item === undefined || item.mode === "write" || !(await this.withdraw(id, submissionId))) return null;
		const data = (item.entry as { data?: InputData } | undefined)?.data;
		if (data?.attachments === undefined && data?.skill === undefined) return { text: textOf(item.content), attachments: [] };
		return {
			text: data.text ?? "",
			attachments: data.attachments === undefined ? [] : editableAttachments(item.content, data.attachments),
			...(data.skill === undefined ? {} : { skill: data.skill }),
		};
	}

	/**
	 * A line said in a Talk to Pi session, as a display-only entry: the model never reads it, and a busy conversation
	 * places it at its next boundary, among the work it was said during. The first thing the user says titles a new
	 * conversation, as a first message does.
	 */
	async voiceLine(input: VoiceLineInput): Promise<void> {
		const { conversationId: id, itemId, ...line } = input;
		const conversation = await this.#conversation(id);
		await conversation.submit(
			{ type: "write", requestId: `voice:${line.session}:${itemId}`, entry: { kind: VoiceEntry, data: line as unknown as JsonValue } },
			context,
		);
		let firstTitle: string | undefined;
		await this.harness.commit(async (tx) => {
			const meta = (await tx.doc(ConversationIndex)).items.find((item) => item.id === id);
			if (meta === undefined) return;
			meta.updatedAt = Date.now();
			if (meta.title === untitled && line.role === "user" && line.text.trim() !== "") meta.title = firstTitle = titleFrom(line.text);
		}, context);
		await this.#changed();
		if (firstTitle !== undefined && intelligenceSettings.titles) void this.#writeTitle(id, line.text, firstTitle);
	}

	/** The Talk to Pi sessions some conversation still shows, archived ones and forks included: their recordings stay. */
	async voiceSessions(): Promise<string[]> {
		const sessions = new Set<string>();
		for (const { id } of await this.#all()) {
			const conversation = await this.#conversation(id);
			let cursor: Parameters<Conversation["entries"]>[2];
			do {
				const page = await conversation.entries({ order: "ascending" }, 200, cursor, context);
				for (const entry of page.items as readonly EntryRecord[]) {
					if (entry.kind === VoiceEntry) sessions.add((entry.data as VoiceLine).session);
				}
				cursor = page.next;
			} while (cursor !== undefined);
			for (const item of (await this.harness.snapshot(InboxDoc, id as never, context))?.items ?? []) {
				if (item.mode === "write" && item.entry?.kind === VoiceEntry) sessions.add((item.entry.data as VoiceLine).session);
			}
		}
		return [...sessions];
	}

	/**
	 * The attachment image files the app still shows or sends: those of every conversation's history, archived ones
	 * included (a fork's includes its parent's up to the fork), and of its queued messages.
	 */
	async attachmentFiles(): Promise<string[]> {
		const files = new Set<string>();
		for (const { id } of await this.#all()) {
			const conversation = await this.#conversation(id);
			let cursor: Parameters<Conversation["entries"]>[2];
			do {
				const page = await conversation.entries({ order: "ascending" }, 200, cursor, context);
				for (const entry of page.items as readonly EntryRecord[]) {
					if (entry.kind === OriginInput) for (const file of attachmentFiles(entry.data)) files.add(file);
				}
				cursor = page.next;
			} while (cursor !== undefined);
			for (const item of (await this.harness.snapshot(InboxDoc, id as never, context))?.items ?? []) {
				if (item.mode !== "write") for (const file of attachmentFiles(item.entry?.data)) files.add(file);
			}
		}
		return [...files];
	}

	/**
	 * Sends a queued message before the current answer ends. While the round's tools run, it becomes a steer, which Pi
	 * places once they finish, before the model's next request. While the model writes, the next boundary would be the
	 * end of the answer, so the answer stops instead (its partial text stays, marked aborted), the message goes next, and
	 * the other queued messages follow it in order. Between withdrawing them and submitting them again they live only
	 * here: a crash in that window drops them.
	 */
	async steer(id: number, submissionId: number): Promise<void> {
		const conversation = await this.#conversation(id);
		const inbox: InboxState | undefined = await this.harness.snapshot(InboxDoc, id as never, context);
		const inputs = (inbox?.items ?? []).filter((item) => item.mode !== "write");
		const target = inputs.find((item) => item.id === submissionId);
		if (target === undefined || !(await this.withdraw(id, submissionId))) return;
		const live = await this.harness.snapshot(LiveDoc, id as never, context);
		// The entry keeps where a message came from (Siri, a widget, a notification reply).
		const submit = ({ content, entry }: (typeof inputs)[number], whenBusy?: "steer" | "followUp") =>
			conversation.submit(
				{ type: "input", content: content as never, whenBusy, requestId: crypto.randomUUID(), ...(entry === undefined ? {} : { entry: entry as never }) },
				context,
			);
		if (live?.run === undefined || live.tools?.some((tool) => tool.status !== "done")) {
			await submit(target, "steer");
			return;
		}
		const rest: typeof inputs = [];
		for (const item of inputs) {
			if (item !== target && (await this.withdraw(id, item.id))) rest.push(item);
		}
		await conversation.abort(context);
		await submit(target);
		for (const item of rest) await submit(item, item.mode);
	}

	/** A new conversation that sees `id`'s transcript through `entryId` and continues on its own. */
	async fork(id: number, entryId: number): Promise<ConversationMeta> {
		const parent = (await this.#all()).find((item) => item.id === id);
		const now = Date.now();
		let meta: ConversationMeta | undefined;
		await (await this.#conversation(id)).fork(
			entryId as never,
			{
				ownership: { kind: "ownerless" },
				init: async (tx, forkId) => {
					meta = {
						id: forkId,
						title: `${parent?.title ?? "Conversation"} (fork)`,
						createdAt: now,
						updatedAt: now,
						forkOf: { conversationId: id, entryId },
					};
					(await tx.doc(ConversationIndex)).items.push(meta);
				},
			},
			context,
		);
		await this.#changed();
		return meta!;
	}

	async rename(id: number, title: string): Promise<void> {
		await this.harness.commit(async (tx) => {
			const meta = (await tx.doc(ConversationIndex)).items.find((item) => item.id === id);
			if (meta !== undefined) meta.title = title.trim() || untitled;
		}, context);
		await this.#changed();
	}

	/** Moves a conversation out of the list into the archive after stopping its work. Its history stays in storage. */
	async archive(id: number): Promise<void> {
		this.unwatch(id);
		await this.abort(id);
		for (const schedule of await this.schedules()) {
			if (schedule.conversationId === id) await this.cancelSchedule(schedule.taskId);
		}
		await this.harness.commit(async (tx) => {
			const meta = (await tx.doc(ConversationIndex)).items.find((item) => item.id === id);
			if (meta !== undefined) meta.archivedAt = Date.now();
		}, context);
		await this.#changed();
	}

	/** Puts an archived conversation back in the list. */
	async unarchive(id: number): Promise<void> {
		await this.harness.commit(async (tx) => {
			const meta = (await tx.doc(ConversationIndex)).items.find((item) => item.id === id);
			if (meta !== undefined) delete meta.archivedAt;
		}, context);
		await this.#changed();
	}

	/**
	 * Deletes a conversation, listed or archived: stops its work and schedules, takes its widgets off the Home Screen and
	 * drops it from the index for good (see `ConversationIndex`). Its forks keep what they show of it.
	 */
	async delete(id: number): Promise<void> {
		if (!(await this.#all()).some((meta) => meta.id === id)) return;
		this.unwatch(id);
		this.#searched.delete(id);
		await this.abort(id);
		for (const schedule of await this.schedules()) {
			if (schedule.conversationId === id) await this.cancelSchedule(schedule.taskId);
		}
		for (const entry of await this.published()) {
			if (entry.conversationId === id) await this.unpublish(entry.publishedId);
		}
		await this.harness.commit(async (tx) => {
			const index = await tx.doc(ConversationIndex);
			const at = index.items.findIndex((item) => item.id === id);
			if (at >= 0) index.items.splice(at, 1);
			index.deleted = [...(index.deleted ?? []), id];
		}, context);
		await this.#changed();
	}

	/**
	 * A conversation as Markdown (export.ts): what was said whole, tool calls folded, thinking left out. `fileName` is the
	 * title made safe for a file.
	 */
	async exportMarkdown(id: number): Promise<{ title: string; fileName: string; markdown: string }> {
		const all = await this.#all();
		const meta = all.find((item) => item.id === id);
		if (meta === undefined) throw new Error(`No conversation ${id}`);
		const view = await readView(await this.#conversation(id), context);
		// Tool results whole up to the transcript's clip; what was said whole.
		const items = entriesOf(view).flatMap((entry): DisplayItem | DisplayItem[] => displayItem(entry, true) ?? []);
		const agent = view.docs["pi.agent"] as { model?: { provider: string; modelId: string } } | undefined;
		const forkOf = meta.forkOf === undefined ? undefined : (all.find((item) => item.id === meta.forkOf!.conversationId)?.title ?? "a deleted conversation");
		const markdown = conversationMarkdown(
			{
				title: meta.title,
				createdAt: meta.createdAt,
				...(agent?.model === undefined ? {} : { model: agent.model }),
				...(forkOf === undefined ? {} : { forkOf }),
				...(meta.archivedAt === undefined ? {} : { archivedAt: meta.archivedAt }),
			},
			items,
		);
		const safe = meta.title.replace(/[\\/:*?"<>|\n\r\t]/g, " ").replace(/\s+/g, " ").trim().slice(0, 80) || "Conversation";
		return { title: meta.title, fileName: `${safe}.md`, markdown };
	}

	/** Every conversation, archived ones included, for the backup archive. */
	async allConversations(): Promise<ConversationMeta[]> {
		return this.#all();
	}

	/** Live tasks with what the scheduler would do with them. */
	async tasks(): Promise<unknown[]> {
		const inspection = await this.harness.inspect(context);
		return inspection.tasks.map(({ record, state }) => ({
			id: record.id,
			kind: record.kind,
			conversationId: record.conversationId,
			state: state.kind,
			reason: state.kind === "blocked" ? state.reason : undefined,
			error: state.kind === "blocked" && state.error !== undefined ? String(state.error) : undefined,
		}));
	}

	async abortTask(id: number): Promise<string> {
		return this.harness.abortTask(id as never, context);
	}

	/** A conversation's surfaces, newest first, as of its latest commit. */
	async surfaces(conversationId: number) {
		const doc = await this.harness.snapshot(SurfacesDoc, conversationId as never, context);
		return Object.values(doc?.items ?? {})
			.sort((a, b) => b.updatedAt - a.updatedAt)
			.map(({ id, version, spec, published, updatedAt }) => ({ conversationId, id, version, spec, published, updatedAt }));
	}

	async published() {
		return [...((await this.harness.snapshot(PublishedDoc, context))?.items ?? [])].sort((a, b) => b.publishedAt - a.publishedAt);
	}

	/** Takes a surface off the Home Screen: removes its widget file and its entry. Its spec stays in the conversation. */
	async unpublish(publishedId: string): Promise<void> {
		await hostCall("ui.unpublish", { publishedId });
		await this.harness.commit(async (tx) => {
			const index = await tx.doc(PublishedDoc);
			const at = index.items.findIndex((item) => item.publishedId === publishedId);
			if (at < 0) return;
			const [entry] = index.items.splice(at, 1);
			const surface = (await tx.doc(SurfacesDoc, entry!.conversationId as never)).items[entry!.surfaceId];
			if (surface?.published?.publishedId === publishedId) delete surface.published;
		}, context);
	}

	async values() {
		return (await this.harness.snapshot(ValuesDoc, context))?.values ?? {};
	}

	answerApproval(id: number, decision: Decision): boolean {
		return this.approvals.answer(id, decision);
	}

	setPolicies(policies: Record<string, ToolPolicy>): void {
		// Tools newer than the stored settings keep their default.
		this.approvals.policies = { ...defaultPolicies, ...policies };
	}
}
