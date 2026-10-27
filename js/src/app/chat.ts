// The chat app's operations on the Harness, called from Swift through `PiRuntime.*`. Swift renders what
// these emit: `frame` events for watched conversations, `conversations` when the list changes, and
// `approvals` when a tool call waits for the user.

import type { AttachedReplicatedState } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { type Conversation, type ConversationView, defineDoc, type Extension, type Harness } from "@earendil-works/pi-durable";
import type { Approvals, Decision, ToolPolicy } from "./approvals.ts";
import { FrameBuilder } from "./display.ts";
import { PublishedDoc, SurfacesDoc, ValuesDoc } from "./surfaces.ts";
import { hostCall } from "../host/hostcall.ts";

const context = BACKGROUND_CONTEXT;

export type ConversationMeta = {
	id: number;
	title: string;
	createdAt: number;
	updatedAt: number;
	/** Set on forks: the conversation and entry they branched from. */
	forkOf?: { conversationId: number; entryId: number };
};

/** The conversations the list shows, newest activity first when read. Conversations are never deleted, only hidden. */
export const ConversationIndex = defineDoc<{ items: ConversationMeta[] }>({
	kind: "app.conversations",
	version: 1,
	scope: "session",
	initial: () => ({ items: [] }),
	checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 50,
});

const untitled = "New conversation";

function titleFrom(text: string): string {
	const line = text.trim().split("\n")[0] ?? "";
	return line.length > 60 ? `${line.slice(0, 57)}…` : line || untitled;
}

export class Chat {
	readonly #watches = new Map<number, { view: AttachedReplicatedState<ConversationView>; unsubscribe: () => void }>();

	constructor(
		private readonly harness: Harness,
		private readonly approvals: Approvals,
		private readonly extensions: readonly Extension[],
		private readonly emit: (event: Record<string, unknown>) => void,
	) {}

	async conversations(): Promise<ConversationMeta[]> {
		const index = await this.harness.snapshot(ConversationIndex, context);
		return [...(index?.items ?? [])].sort((a, b) => b.updatedAt - a.updatedAt);
	}

	async #changed(): Promise<void> {
		this.emit({ type: "conversations", items: await this.conversations() });
	}

	async create(model: { provider: string; modelId: string }): Promise<ConversationMeta> {
		const now = Date.now();
		let meta: ConversationMeta | undefined;
		await this.harness.createConversation(
			{
				ownership: { kind: "ownerless" },
				agent: { model, extensions: [...this.extensions] },
				init: async (tx, id) => {
					meta = { id, title: untitled, createdAt: now, updatedAt: now };
					(await tx.doc(ConversationIndex)).items.push(meta);
				},
			},
			context,
		);
		await this.#changed();
		return meta!;
	}

	async #conversation(id: number): Promise<Conversation> {
		const conversation = await this.harness.conversation(id as never, context);
		if (conversation === undefined) throw new Error(`No conversation ${id}`);
		return conversation;
	}

	/** Starts `frame` events for one conversation; the first frame holds the whole transcript. */
	async watch(id: number): Promise<void> {
		this.unwatch(id);
		const conversation = await this.#conversation(id);
		const view = await conversation.viewState(context);
		const builder = new FrameBuilder(id);
		const send = (value: ConversationView) => this.emit({ type: "frame", frame: builder.frame(value) });
		const unsubscribe = view.subscribe((value) => send(value));
		this.#watches.set(id, { view, unsubscribe });
		send(view.value);
	}

	/** The whole transcript and live state once, as one frame (headless checks read this). */
	async transcript(id: number) {
		const view = await (await this.#conversation(id)).viewState(context);
		try {
			return new FrameBuilder(id).frame(view.value);
		} finally {
			view.dispose();
		}
	}

	unwatch(id: number): void {
		const watch = this.#watches.get(id);
		if (watch === undefined) return;
		this.#watches.delete(id);
		watch.unsubscribe();
		watch.view.dispose();
	}

	/** Admits a user message; while a run is going it queues as a follow-up. Never waits for the answer. */
	async send(id: number, text: string, requestId: string): Promise<{ submissionId: number }> {
		const conversation = await this.#conversation(id);
		const submission = await conversation.submit({ type: "input", content: text, requestId }, context);
		const now = Date.now();
		await this.harness.commit(async (tx) => {
			const meta = (await tx.doc(ConversationIndex)).items.find((item) => item.id === id);
			if (meta === undefined) return;
			meta.updatedAt = now;
			if (meta.title === untitled) meta.title = titleFrom(text);
		}, context);
		await this.#changed();
		return { submissionId: submission.id };
	}

	/** Stops the run and withdraws queued messages; resolves once the conversation is idle. */
	async abort(id: number): Promise<void> {
		await (await this.#conversation(id)).abort(context);
	}

	/** A new conversation that sees `id`'s transcript through `entryId` and continues on its own. */
	async fork(id: number, entryId: number): Promise<ConversationMeta> {
		const parent = (await this.conversations()).find((item) => item.id === id);
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

	/** Hides a conversation from the list after stopping its work. Its history stays in storage. */
	async remove(id: number): Promise<void> {
		this.unwatch(id);
		await this.abort(id);
		await this.harness.commit(async (tx) => {
			const index = await tx.doc(ConversationIndex);
			const at = index.items.findIndex((item) => item.id === id);
			if (at >= 0) index.items.splice(at, 1);
		}, context);
		await this.#changed();
	}

	async setModel(id: number, provider: string, modelId: string): Promise<void> {
		await (await this.#conversation(id)).configure({ model: { provider, modelId } }, context);
	}

	/** Live tasks with what the scheduler would do with them; parked ones (`restart_limit`) can be retried. */
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

	async retryTask(id: number): Promise<void> {
		await this.harness.retryTask(id as never, context);
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
		this.approvals.policies = { ...policies };
	}
}
