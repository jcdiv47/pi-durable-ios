// The app's harness bootstrap, evaluated once per process in PiRuntime's JSContext.
// Swift drives it through `globalThis.PiRuntime` (see Packages/PiRuntime/Sources/PiRuntime/PiHarness.swift).

import "./host/polyfills.ts";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { deepseekProvider } from "@earendil-works/pi-ai/providers/deepseek";
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
import { createKillTestFaux, KillTestTools } from "./killtest.ts";
import { fetchStats } from "./host/fetch.ts";
import { native } from "./host/native.ts";
import { openIOSSqliteDatabase } from "./host/sqlite.ts";

const context = BACKGROUND_CONTEXT;

/** Header value Swift's fetch replaces with the Keychain key; must match `ProviderKeys.placeholder(for:)`. */
const keyPlaceholder = (provider: string) => `pi-host-key:${provider}`;

/** The env variable pi-ai reads each keyed provider's API key from. */
const keyEnvironment: Record<string, string> = {
	ANTHROPIC_API_KEY: "anthropic",
	DEEPSEEK_API_KEY: "deepseek",
};

function emit(event: Record<string, unknown>): void {
	native.emit(JSON.stringify(event));
}

export interface OpenOptions {
	readonly dbPath: string;
	readonly provider: "anthropic" | "deepseek" | "faux";
	readonly modelId: string;
	/** Providers whose keys Swift holds; only these get a placeholder key. */
	readonly keyedProviders?: readonly string[];
	/** Milliseconds the kill test's tools take. */
	readonly toolMs?: number;
}

let harness: Harness | undefined;
let root: Conversation | undefined;

async function open(options: OpenOptions): Promise<{ openMs: number; rootId: number; wake: Wake }> {
	if (harness !== undefined) throw new Error("PiRuntime is already open");
	const t0 = performance.now();
	const keyed = new Set(options.keyedProviders ?? []);
	const models = createModels({
		authContext: {
			env: async (name) => {
				const provider = keyEnvironment[name];
				return provider !== undefined && keyed.has(provider) ? keyPlaceholder(provider) : undefined;
			},
			fileExists: async () => false,
		},
		identity: { attribution: { name: "pi-durable-ios", url: "https://github.com/earendil-works/pi" } },
	});
	models.setProvider(anthropicProvider());
	models.setProvider(deepseekProvider());
	models.setProvider(createKillTestFaux().provider);

	const registry = createRegistry();
	registry.install(KillTestTools(options.toolMs ?? 6000));

	const storage = await SqliteStorage.open(openIOSSqliteDatabase(options.dbPath), { prefix: "pi_" });
	const tStorage = performance.now();
	harness = await Harness.open(
		storage,
		{
			models,
			registry,
			// iOS evicts the process; Swift arms BackgroundTasks / notifications from these (M3). M0 logs them.
			onWake: (wake) => emit({ type: "wake", wake }),
			onReport: (error, info) =>
				emit({ type: "report", info, error: error instanceof Error ? `${error.name}: ${error.message}` : String(error) }),
			settings: { toolExecution: "parallel" },
		},
		context,
	);
	const tHarness = performance.now();
	root = await harness.root(context, { agent: { model: { provider: options.provider, modelId: options.modelId } } });
	const wake = harness.wake();
	emit({
		type: "opened",
		storageMs: tStorage - t0,
		harnessMs: tHarness - tStorage,
		rootMs: performance.now() - tHarness,
	});
	harness.resume();
	return { openMs: performance.now() - t0, rootId: root.id, wake };
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

function answerText(entry: EntryRecord | undefined): string {
	const message = (entry?.model as { content?: { type: string; text?: string }[] }[] | undefined)?.[0];
	return (message?.content ?? [])
		.filter((block) => block.type === "text")
		.map((block) => block.text ?? "")
		.join("");
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
	const current = harness;
	harness = undefined;
	root = undefined;
	await current?.close(context);
}

(globalThis as Record<string, unknown>).PiRuntime = { open, watch, ask, submit, settle, entries, close };
