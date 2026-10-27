// The app's harness bootstrap, evaluated once per process in PiRuntime's JSContext.
// Swift drives it through `globalThis.PiRuntime` (see Packages/PiRuntime/Sources/PiRuntime/PiHarness.swift).

import "./host/polyfills.ts";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { ModelThinkingLevel } from "@earendil-works/pi-ai";
import {
	AssistantEntry,
	type Conversation,
	createRegistry,
	type EntryRecord,
	Harness,
	type Wake,
	watchEvents,
} from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { AppleTools, appleToolInfo } from "./app/apple.ts";
import { Approvals, type Decision, type ToolPolicy } from "./app/approvals.ts";
import { Chat, type OutsideInput, type WidgetAction } from "./app/chat.ts";
import { type CustomProvider, ModelSetup } from "./app/models.ts";
import { answerText, ScheduleTools, scheduleToolInfo } from "./app/schedule.ts";
import { SurfaceTools, surfaceToolInfo } from "./app/surfaces.ts";
import { createKillTestFaux, KillTestTools } from "./killtest.ts";
import { fetchStats } from "./host/fetch.ts";
import { native } from "./host/native.ts";
import { openIOSSqliteDatabase } from "./host/sqlite.ts";

const context = BACKGROUND_CONTEXT;

function emit(event: Record<string, unknown>): void {
	native.emit(JSON.stringify(event));
}

export interface OpenOptions {
	readonly dbPath: string;
	/** The root conversation's model (M0 modes and scripts use the root). */
	readonly provider: string;
	readonly modelId: string;
	/** Providers whose keys Swift holds; only these get a placeholder key. */
	readonly keyedProviders?: readonly string[];
	readonly customProvider?: CustomProvider;
	readonly policies?: Record<string, ToolPolicy>;
	/** Milliseconds the kill test's tools take. */
	readonly toolMs?: number;
}

let harness: Harness | undefined;
let root: Conversation | undefined;
let chat: Chat | undefined;
const setup = new ModelSetup();
const approvals = new Approvals((pending) => emit({ type: "approvals", pending }));
let wakeTimer: ReturnType<typeof setTimeout> | undefined;

/**
 * With `onWake` the Harness arms no timer for sleeps; the host does. While the process lives, a JS timer resumes
 * due sleeps; Swift arms a BGAppRefreshTask from the same event for when iOS has suspended or evicted it.
 */
function onWake(wake: Wake): void {
	clearTimeout(wakeTimer);
	wakeTimer = wake.at === undefined ? undefined : setTimeout(() => harness?.resume(), Math.max(0, wake.at - Date.now()) + 50);
	emit({ type: "wake", wake });
}

async function open(options: OpenOptions): Promise<{ openMs: number; rootId: number; wake: Wake }> {
	if (harness !== undefined) throw new Error("PiRuntime is already open");
	const t0 = performance.now();
	configureProviders(options.keyedProviders ?? [], options.customProvider);
	if (options.policies !== undefined) approvals.policies = { ...options.policies };
	const models = setup.models;
	models.setProvider(createKillTestFaux().provider);

	const registry = createRegistry();
	registry.install(KillTestTools(options.toolMs ?? 6000));
	const approvalGate = approvals.extension();
	registry.install(AppleTools);
	registry.install(SurfaceTools);
	const scheduleTools = ScheduleTools((taskId) => requireOpen().harness.abortTask(taskId as never, context));
	registry.install(scheduleTools);
	registry.install(approvalGate);

	const storage = await SqliteStorage.open(openIOSSqliteDatabase(options.dbPath), { prefix: "pi_" });
	const tStorage = performance.now();
	harness = await Harness.open(
		storage,
		{
			models,
			registry,
			// iOS suspends and evicts the process; see onWake above.
			onWake,
			onReport: (error, info) =>
				emit({ type: "report", info, error: error instanceof Error ? `${error.name}: ${error.message}` : String(error) }),
			settings: { toolExecution: "parallel" },
		},
		context,
	);
	const tHarness = performance.now();
	root = await harness.root(context, {
		agent: { model: { provider: options.provider, modelId: options.modelId }, extensions: [KillTestTools(0)] },
	});
	chat = new Chat(harness, approvals, [AppleTools, SurfaceTools, scheduleTools, approvalGate], emit, (model, level) =>
		setup.clampThinking(model, level),
	);
	await chat.upgrade();
	const wake = harness.wake();
	onWake(wake);
	emit({
		type: "opened",
		storageMs: tStorage - t0,
		harnessMs: tHarness - tStorage,
		rootMs: performance.now() - tHarness,
	});
	harness.resume();
	return { openMs: performance.now() - t0, rootId: root.id, wake };
}

/** Keys or the custom endpoint changed in Settings; applies from the next request. */
function configureProviders(keyedProviders: readonly string[], custom?: CustomProvider): void {
	setup.keyed = new Set(keyedProviders);
	setup.setCustom(custom);
}

function requireChat(): Chat {
	if (chat === undefined) throw new Error("PiRuntime is not open");
	return chat;
}

function requireOpen(): { harness: Harness; root: Conversation } {
	if (harness === undefined || root === undefined) throw new Error("PiRuntime is not open");
	return { harness, root };
}

/** Streams agent events to Swift as `{ type: "agent", events }` batches until `stop()`. */
async function watch(): Promise<() => Promise<unknown>> {
	const { harness, root } = requireOpen();
	const stream = await watchEvents(harness, root.id, context);
	stream.start(async (events) => {
		emit({ type: "agent", events });
	});
	return () => stream.stop();
}

/**
 * Submits one input and waits for its answer, timing the stream. Reasoning models (DeepSeek) stream
 * thinking before text, and their output token count includes it, so time per token spans both.
 */
async function ask(text: string, requestId: string): Promise<Record<string, unknown>> {
	const { harness, root } = requireOpen();
	const t0 = performance.now();
	const network0 = { ...fetchStats };
	// Measure network timing from this call's chunks only.
	fetchStats.chunks = 0;
	let firstDeltaMs: number | undefined;
	let firstTextMs: number | undefined;
	let lastDeltaMs: number | undefined;
	let textDeltas = 0;
	let thinkingDeltas = 0;
	let textChars = 0;
	let thinkingChars = 0;
	const stream = await watchEvents(harness, root.id, context);
	stream.start(async (events) => {
		for (const event of events) {
			if (event.type !== "message_update") continue;
			for (const change of event.changes) {
				if (change.type !== "text_delta" && change.type !== "thinking_delta") continue;
				const now = performance.now() - t0;
				firstDeltaMs ??= now;
				lastDeltaMs = now;
				if (change.type === "text_delta") {
					firstTextMs ??= now;
					textDeltas++;
					textChars += change.delta.length;
				} else {
					thinkingDeltas++;
					thinkingChars += change.delta.length;
				}
				emit({ type: "delta", kind: change.type === "text_delta" ? "text" : "thinking", text: change.delta, ms: now });
			}
		}
	});
	try {
		const submission = await root.submit({ type: "input", content: text, requestId }, context);
		const settled = await submission.wait(context);
		const totalMs = performance.now() - t0;
		if (settled.status !== "done" || settled.type !== "input") {
			return { status: settled.status, detail: JSON.stringify(settled).slice(0, 2000), totalMs };
		}
		const answer = await root.commit((tx) => tx.entry(AssistantEntry, settled.answer), context);
		const message = (answer?.model as { usage?: { output?: number }; stopReason?: string; errorMessage?: string }[] | undefined)?.[0];
		const outputTokens = message?.usage?.output;
		const streamMs = firstDeltaMs !== undefined && lastDeltaMs !== undefined ? lastDeltaMs - firstDeltaMs : undefined;
		return {
			status: "done",
			text: answerText(answer),
			stopReason: message?.stopReason,
			errorMessage: message?.errorMessage,
			totalMs,
			firstDeltaMs,
			firstTextMs,
			streamMs,
			deltas: textDeltas + thinkingDeltas,
			textDeltas,
			thinkingDeltas,
			textChars,
			thinkingChars,
			outputTokens,
			msPerToken: outputTokens && streamMs !== undefined ? streamMs / outputTokens : undefined,
			// Network chunks vs. deltas: Pi emits deltas from its throttled durable partial, not per chunk.
			networkChunks: fetchStats.chunks,
			networkBytes: fetchStats.bytes - network0.bytes,
			// Time per token as the network delivered it (first to last body chunk of the call).
			networkMsPerToken:
				outputTokens && fetchStats.chunks > 1 ? (fetchStats.lastChunkAt - fetchStats.firstChunkAt) / outputTokens : undefined,
		};
	} finally {
		await stream.stop();
	}
}

/** Admits an input without waiting: the kill test terminates the process while it runs. */
async function submit(text: string, requestId: string): Promise<{ submissionId: number }> {
	const { root } = requireOpen();
	const submission = await root.submit({ type: "input", content: text, requestId }, context);
	return { submissionId: submission.id };
}

/** After a relaunch: waits for the run `requestId` started and reports what the transcript holds. */
async function settle(text: string, requestId: string): Promise<Record<string, unknown>> {
	const { harness, root } = requireOpen();
	// The same requestId finds the submission the killed process admitted instead of submitting twice.
	const submission = await root.submit({ type: "input", content: text, requestId }, context);
	const settled = await submission.wait(context);
	const view = await root.viewState(context);
	const entries = view.value.entries as unknown as EntryRecord[];
	view.dispose();
	const toolResults = entries
		.filter((entry) => entry.kind === "pi.tool-result")
		.map((entry) => {
			const message = (entry.model as unknown as { toolName: string; isError: boolean; content: { text?: string }[] }[])[0]!;
			return {
				tool: message.toolName,
				isError: message.isError,
				text: message.content.map((c) => c.text ?? "").join(""),
				diagnostics: (entry.data as { diagnostics?: unknown } | undefined)?.diagnostics,
			};
		});
	const answer =
		settled.status === "done" && settled.type === "input"
			? answerText(await root.commit((tx) => tx.entry(AssistantEntry, settled.answer), context))
			: undefined;
	return {
		status: settled.status,
		submissionId: submission.id,
		entryKinds: entries.map((e) => e.kind),
		toolResults,
		answer,
		inspection: summarizeInspection(await harness.inspect(context)),
	};
}

function summarizeInspection(inspection: unknown): unknown {
	try {
		return JSON.parse(JSON.stringify(inspection));
	} catch {
		return String(inspection);
	}
}

/** Debugging aid: entry kinds and texts of the root transcript, after the conversation is idle. */
async function entries(): Promise<unknown> {
	const { harness, root } = requireOpen();
	await harness.waitForIdle(context);
	const view = await root.viewState(context);
	const list = (view.value.entries as unknown as EntryRecord[]).map((e) => ({ id: e.id, kind: e.kind, model: JSON.stringify(e.model).slice(0, 160) }));
	view.dispose();
	return list;
}

async function close(): Promise<void> {
	clearTimeout(wakeTimer);
	const current = harness;
	harness = undefined;
	root = undefined;
	chat = undefined;
	await current?.close(context);
}

/** The chat app's API (see app/chat.ts); every method resolves to JSON for Swift. */
const app = {
	conversations: () => requireChat().conversations(),
	createConversation: (provider: string, modelId: string, thinkingLevel?: ModelThinkingLevel) =>
		requireChat().create({ provider, modelId }, undefined, thinkingLevel),
	watchConversation: (id: number) => requireChat().watch(id),
	unwatchConversation: async (id: number) => requireChat().unwatch(id),
	transcript: (id: number) => requireChat().transcript(id),
	searchText: (id: number) => requireChat().searchText(id),
	send: (id: number, text: string, requestId: string) => requireChat().send(id, text, requestId),
	abort: (id: number) => requireChat().abort(id),
	withdraw: (id: number, submissionId: number) => requireChat().withdraw(id, submissionId),
	steer: (id: number, submissionId: number) => requireChat().steer(id, submissionId),
	fork: (id: number, entryId: number) => requireChat().fork(id, entryId),
	rename: (id: number, title: string) => requireChat().rename(id, title),
	removeConversation: (id: number) => requireChat().remove(id),
	setModel: (id: number, provider: string, modelId: string) => requireChat().setModel(id, provider, modelId),
	setThinking: (id: number, level: ModelThinkingLevel) => requireChat().setThinking(id, level),
	tasks: () => requireChat().tasks(),
	retryTask: (id: number) => requireChat().retryTask(id),
	abortTask: (id: number) => requireChat().abortTask(id),
	approvals: async () => approvals.pending(),
	answerApproval: async (id: number, decision: Decision) => requireChat().answerApproval(id, decision),
	setPolicies: async (policies: Record<string, ToolPolicy>) => requireChat().setPolicies(policies),
	tools: async () =>
		[...appleToolInfo, ...surfaceToolInfo, ...scheduleToolInfo].map((tool) => ({ ...tool, policy: approvals.policy(tool.name) })),
	surfaces: (conversationId: number) => requireChat().surfaces(conversationId),
	publishedSurfaces: () => requireChat().published(),
	unpublishSurface: (publishedId: string) => requireChat().unpublish(publishedId),
	surfaceValues: () => requireChat().values(),
	configureProviders: async (keyedProviders: string[], custom?: CustomProvider) => configureProviders(keyedProviders, custom),
	models: async () => setup.available(),
	usage: async () => JSON.parse(JSON.stringify(await requireOpen().harness.usage(context))),
	// Entry points outside the chat (App Intents, widget buttons, notification actions); each carries a request ID.
	askFromOutside: (input: OutsideInput) => requireChat().ask(input),
	widgetAction: (publishedId: string, action: WidgetAction, requestId: string, provider: string, modelId: string) =>
		requireChat().widgetAction(publishedId, action, requestId, { provider, modelId }),
	schedules: () => requireChat().schedules(),
	runSchedule: (name: string, requestId: string, waitMs: number, provider: string, modelId: string) =>
		requireChat().runSchedule(name, requestId, waitMs, { provider, modelId }),
	cancelSchedule: (taskId: number) => requireChat().cancelSchedule(taskId),
	/** BackgroundTasks and app activation: runs due sleeps and work a lost process left; returns what is left. */
	resume: async () => {
		const { harness } = requireOpen();
		harness.resume();
		return harness.wake();
	},
	wake: async () => requireOpen().harness.wake(),
};

(globalThis as Record<string, unknown>).PiRuntime = { open, watch, ask, submit, settle, entries, close, ...app };
