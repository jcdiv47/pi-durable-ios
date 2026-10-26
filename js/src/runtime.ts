// The app's harness bootstrap, evaluated once per process in PiRuntime's JSContext.
// Swift drives it through `globalThis.PiRuntime` (see Packages/PiRuntime/Sources/PiRuntime/PiHarness.swift).

import "./host/polyfills.ts";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
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
import { native } from "./host/native.ts";
import { openIOSSqliteDatabase } from "./host/sqlite.ts";

const context = BACKGROUND_CONTEXT;

/** Header value Swift's fetch replaces with the Keychain key; must match `ProviderKeys.placeholder(for:)`. */
const keyPlaceholder = (provider: string) => `pi-host-key:${provider}`;

function emit(event: Record<string, unknown>): void {
	native.emit(JSON.stringify(event));
}

export interface OpenOptions {
	readonly dbPath: string;
	readonly provider: "anthropic" | "faux";
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
			env: async (name) => (name === "ANTHROPIC_API_KEY" && keyed.has("anthropic") ? keyPlaceholder("anthropic") : undefined),
			fileExists: async () => false,
		},
		identity: { attribution: { name: "pi-durable-ios", url: "https://github.com/earendil-works/pi" } },
	});
	models.setProvider(anthropicProvider());
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

/** Submits one input and waits for its answer, timing the first streamed delta. */
async function ask(text: string, requestId: string): Promise<Record<string, unknown>> {
	const { harness, root } = requireOpen();
	const t0 = performance.now();
	let firstDeltaMs: number | undefined;
	let lastDeltaMs: number | undefined;
	let deltas = 0;
	let deltaChars = 0;
	const stream = await watchEvents(harness, root.id, context);
	stream.start(async (events) => {
		for (const event of events) {
			if (event.type !== "message_update") continue;
			for (const change of event.changes) {
				if (change.type !== "text_delta") continue;
				const now = performance.now() - t0;
				firstDeltaMs ??= now;
				lastDeltaMs = now;
				deltas++;
				deltaChars += change.delta.length;
				emit({ type: "delta", text: change.delta, ms: now });
			}
		}
	});
	try {
		const submission = await root.submit({ type: "input", content: text, requestId }, context);
		const settled = await submission.wait(context);
		const totalMs = performance.now() - t0;
		if (settled.status !== "done" || settled.type !== "input") {
			return { status: settled.status, settled, totalMs };
		}
		const answer = await root.commit((tx) => tx.entry(AssistantEntry, settled.answer), context);
		const message = (answer?.model as { usage?: { output?: number } }[] | undefined)?.[0];
		const outputTokens = message?.usage?.output;
		const streamMs = firstDeltaMs !== undefined && lastDeltaMs !== undefined ? lastDeltaMs - firstDeltaMs : undefined;
		return {
			status: "done",
			text: answerText(answer),
			totalMs,
			firstDeltaMs,
			streamMs,
			deltas,
			deltaChars,
			outputTokens,
			msPerToken: outputTokens && streamMs !== undefined ? streamMs / outputTokens : undefined,
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
async function settle(requestId: string, text: string): Promise<Record<string, unknown>> {
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

async function close(): Promise<void> {
	const current = harness;
	harness = undefined;
	root = undefined;
	await current?.close(context);
}

(globalThis as Record<string, unknown>).PiRuntime = { open, watch, ask, submit, settle, close };
