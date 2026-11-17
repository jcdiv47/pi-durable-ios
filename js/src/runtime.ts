// The app's harness bootstrap, evaluated once per process in PiRuntime's JSContext.
// Swift drives it through `globalThis.PiRuntime` (see Packages/PiRuntime/Sources/PiRuntime/PiHarness.swift).

import "./host/polyfills.ts";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { ModelThinkingLevel } from "@earendil-works/pi-ai";
import {
	AssistantEntry,
	type Conversation,
	createRegistry,
	Harness,
	type LiveState,
	type Wake,
} from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { AppleTools, appleToolInfo } from "./app/apple.ts";
import { Approvals, type Decision, defaultPolicies, type ToolPolicy } from "./app/approvals.ts";
import type { InputAttachment } from "./app/attachments.ts";
import { CodeModeTools, codeModeToolInfo } from "./app/codemode.ts";
import { Chat, intelligenceSettings, type OutsideInput, type WidgetAction } from "./app/chat.ts";
import type { SearchOptions } from "./app/search.ts";
import type { VoiceLineInput } from "./app/voice.ts";
import { InstructionsExtension, instructionsSettings } from "./app/instructions.ts";
import { McpHost, type McpServerConfig } from "./app/mcp.ts";
import { type AppleModel, type CustomProvider, ModelSetup } from "./app/models.ts";
import { waitWhileOffline } from "./app/network.ts";
import { answerText, ScheduleTools, scheduleToolInfo } from "./app/schedule.ts";
import { SkillHost, type SkillInfo } from "./app/skills.ts";
import { type SshHostConfig, sshSettings, SshTools, sshToolInfo, sshTrusted } from "./app/ssh.ts";
import { SurfaceTools, surfaceToolInfo } from "./app/surfaces.ts";
import { fetchTrusted, type SearchProviderId, WebTools, webSettings, webToolInfo } from "./app/web.ts";
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
	/** Apple Intelligence models that can run now. */
	readonly appleModels?: readonly AppleModel[];
	/** Settings › Apple Intelligence › Titles: on-device conversation titles. */
	readonly intelligenceTitles?: boolean;
	/** Where `web_search` searches: Settings › Web search. */
	readonly searchProvider?: SearchProviderId;
	readonly policies?: Record<string, ToolPolicy>;
	/** Settings › MCP servers as JSON text (`McpServerConfig[]`), with each server's cached tool list. */
	readonly mcpServers?: string;
	/** Settings › SSH Hosts, without secrets. */
	readonly sshHosts?: readonly SshHostConfig[];
	/** Settings › Instructions: the user's AGENTS.md text. */
	readonly instructions?: string;
	/** Settings › Skills: the imported skills, as Swift parsed them. */
	readonly skills?: readonly SkillInfo[];
	/** Milliseconds the kill test's tools take. */
	readonly toolMs?: number;
}

let harness: Harness | undefined;
let root: Conversation | undefined;
let chat: Chat | undefined;
const setup = new ModelSetup();
// Every model request the Harness makes waits while the phone is offline instead of failing (app/network.ts).
setup.models.streamSimple = waitWhileOffline(setup.models.streamSimple.bind(setup.models), {
	online: () => native.networkOnline(),
	onWaiting: (waiting) => emit({ type: "network", waiting }),
});
webSettings.keyed = (service) => setup.keyed.has(service);
const approvals = new Approvals((pending) => emit({ type: "approvals", pending }));
const mcp = new McpHost(undefined, (statuses) => emit({ type: "mcp", statuses }));
approvals.dynamicDefaults = () => mcp.defaultPolicies();
const skills = new SkillHost();
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
	setup.setApple(options.appleModels ?? []);
	intelligenceSettings.titles = options.intelligenceTitles ?? false;
	if (options.policies !== undefined) approvals.policies = { ...defaultPolicies, ...options.policies };
	webSettings.provider = options.searchProvider ?? "off";
	const models = setup.models;
	models.setProvider(createKillTestFaux().provider);

	const registry = createRegistry();
	registry.install(KillTestTools(options.toolMs ?? 6000));
	const approvalGate = approvals.extension();
	registry.install(AppleTools);
	registry.install(SurfaceTools);
	registry.install(WebTools);
	sshSettings.hosts = [...(options.sshHosts ?? [])];
	registry.install(SshTools);
	// From the cached tool lists, so a call a crash interrupted finds its tool before any server answers.
	mcp.install = (extension) => registry.install(extension);
	mcp.setServers(parseServers(options.mcpServers));
	instructionsSettings.text = options.instructions ?? "";
	registry.install(InstructionsExtension);
	// From Swift's list, so a skill read a crash interrupted finds its tool on resume.
	skills.install = (extension) => registry.install(extension);
	skills.setSkills([...(options.skills ?? [])]);
	const scheduleTools = ScheduleTools((taskId) => requireOpen().harness.abortTask(taskId as never, context));
	registry.install(scheduleTools);
	registry.install(CodeModeTools);
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
			onReport: ({ error, ...info }) =>
				emit({ type: "report", info, error: error instanceof Error ? `${error.name}: ${error.message}` : String(error) }),
			settings: {
				toolExecution: "parallel",
				// The on-device model's window (4,096) is below the default reserve; its endpoint trims history instead.
				compaction: { modelOverrides: { "apple/on-device": { enabled: false } } },
			},
		},
		context,
	);
	const tHarness = performance.now();
	root = await harness.root(context, {
		agent: { model: { provider: options.provider, modelId: options.modelId }, extensions: [KillTestTools(0)] },
	});
	chat = new Chat(harness, approvals, [AppleTools, SurfaceTools, WebTools, SshTools, mcp.extension, scheduleTools, InstructionsExtension, skills.extension, CodeModeTools, approvalGate], emit, (model, level) =>
		setup.clampThinking(model, level),
	);
	await chat.upgrade();
	approvals.trusted.web_fetch = async (args, conversationId, context) => {
		const conversation = await harness?.conversation(conversationId as never, context);
		if (conversation === undefined) return false;
		// The URLs the model has seen: its active transcript.
		return fetchTrusted(args, (await conversation.context(context)).entries);
	};
	approvals.trusted.ssh_exec = async (args, conversationId, context) => {
		const conversation = await harness?.conversation(conversationId as never, context);
		return conversation !== undefined && sshTrusted(args, (await conversation.context(context)).entries);
	};
	const wake = harness.wake();
	onWake(wake);
	emit({
		type: "opened",
		storageMs: tStorage - t0,
		harnessMs: tHarness - tStorage,
		rootMs: performance.now() - tHarness,
	});
	harness.resume();
	// Fresh tool lists; Swift caches what comes back (`mcp` events).
	void mcp.refresh();
	return { openMs: performance.now() - t0, rootId: root.id, wake };
}

function parseServers(json: string | undefined): McpServerConfig[] {
	if (json === undefined || json === "") return [];
	const parsed = JSON.parse(json) as unknown;
	return Array.isArray(parsed) ? (parsed as McpServerConfig[]) : [];
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

/**
 * Submits one input and waits for its answer, timing the stream. Reasoning models (DeepSeek) stream
 * thinking before text, and their output token count includes it, so time per token spans both.
 */
async function ask(text: string, requestId: string): Promise<Record<string, unknown>> {
	const { root } = requireOpen();
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
	// The streamed answer is `pi.live.generation.message`; a delta is what its text or thinking gained since the last
	// value the watch delivered (commits made while the listener ran arrive folded into one).
	let seen = { text: 0, thinking: 0 };
	const delta = (kind: "text" | "thinking", value: string) => {
		if (value.length <= seen[kind]) return;
		const text = value.slice(seen[kind]);
		seen[kind] = value.length;
		const now = performance.now() - t0;
		firstDeltaMs ??= now;
		lastDeltaMs = now;
		if (kind === "text") {
			firstTextMs ??= now;
			textDeltas++;
			textChars += text.length;
		} else {
			thinkingDeltas++;
			thinkingChars += text.length;
		}
		emit({ type: "delta", kind, text, ms: now });
	};
	const stream = await root.watch(context, { min: 1 });
	stream.start(async (call) => {
		if (call.kind !== "value") return;
		const message = (call.value.docs["pi.live"] as LiveState | undefined)?.generation?.message;
		const blocks = (message?.content ?? []) as { type: string; text?: string; thinking?: string }[];
		const text = blocks.map((block) => (block.type === "text" ? (block.text ?? "") : "")).join("");
		const thinking = blocks.map((block) => (block.type === "thinking" ? (block.thinking ?? "") : "")).join("");
		// A new message (the next turn, a retry) starts over.
		if (message === undefined || text.length < seen.text || thinking.length < seen.thinking) seen = { text: 0, thinking: 0 };
		delta("thinking", thinking);
		delta("text", text);
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
	const { entries } = await root.context(context);
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
	const { entries } = await root.context(context);
	return entries.map((e) => ({ id: e.id, kind: e.kind, model: JSON.stringify(e.model).slice(0, 160) }));
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
	searchConversations: (query: string, options?: SearchOptions) => requireChat().search(query, options ?? undefined),
	spending: (from: number, to: number) => requireChat().spending(from, to),
	send: (id: number, text: string, requestId: string, attachments?: InputAttachment[], skill?: string) =>
		requireChat().send(id, text, requestId, attachments, skill ?? undefined),
	abort: (id: number) => requireChat().abort(id),
	withdraw: (id: number, submissionId: number) => requireChat().withdraw(id, submissionId),
	steer: (id: number, submissionId: number) => requireChat().steer(id, submissionId),
	takeBack: (id: number, submissionId: number) => requireChat().takeBack(id, submissionId),
	attachmentFiles: () => requireChat().attachmentFiles(),
	voiceSessions: () => requireChat().voiceSessions(),
	fork: (id: number, entryId: number) => requireChat().fork(id, entryId),
	rename: (id: number, title: string) => requireChat().rename(id, title),
	archiveConversation: (id: number) => requireChat().archive(id),
	unarchiveConversation: (id: number) => requireChat().unarchive(id),
	archivedConversations: () => requireChat().archivedConversations(),
	deleteConversation: (id: number) => requireChat().delete(id),
	exportMarkdown: (id: number) => requireChat().exportMarkdown(id),
	allConversations: () => requireChat().allConversations(),
	tasks: () => requireChat().tasks(),
	abortTask: (id: number) => requireChat().abortTask(id),
	approvals: async () => approvals.pending(),
	answerApproval: async (id: number, decision: Decision) => requireChat().answerApproval(id, decision),
	setPolicies: async (policies: Record<string, ToolPolicy>) => requireChat().setPolicies(policies),
	tools: async () =>
		[...appleToolInfo, ...webToolInfo, ...sshToolInfo, ...surfaceToolInfo, ...scheduleToolInfo, ...codeModeToolInfo, ...mcp.toolInfo()].map((tool) => ({
			...tool,
			policy: approvals.policy(tool.name),
		})),
	surfaces: (conversationId: number) => requireChat().surfaces(conversationId),
	publishedSurfaces: () => requireChat().published(),
	unpublishSurface: (publishedId: string) => requireChat().unpublish(publishedId),
	surfaceValues: () => requireChat().values(),
	configureProviders: async (keyedProviders: string[], custom?: CustomProvider) => configureProviders(keyedProviders, custom),
	/** Apple Intelligence became available or not, and whether it writes titles. */
	setAppleIntelligence: async (models: AppleModel[], titles: boolean) => {
		setup.setApple(models);
		intelligenceSettings.titles = titles;
	},
	setSearchProvider: async (provider: SearchProviderId) => {
		webSettings.provider = provider;
	},
	models: async () => setup.available(),
	// Settings › MCP servers: the list changed (JSON text, as in `open`). Swift then calls `refreshMcp` for the server.
	setMcpServers: async (json: string) => mcp.setServers(parseServers(json)),
	/** Lists the tools of every enabled server (or those in `ids`) again; returns their statuses. */
	refreshMcp: (ids?: string[]) => mcp.refresh(ids),
	mcpStatuses: async () => mcp.statuses(),
	// Settings › MCP servers › Sign in, for OAuth servers: the page to show, then the URL it redirected to.
	mcpBeginSignIn: (id: string) => mcp.beginSignIn(id),
	mcpFinishSignIn: (id: string, callbackUrl: string) => mcp.finishSignIn(id, callbackUrl),
	mcpSignOut: (id: string) => mcp.signOut(id),
	// Settings › SSH Hosts changed; applies from the next tool call and model request.
	setSshHosts: async (hosts: SshHostConfig[]) => {
		sshSettings.hosts = [...hosts];
	},
	// Settings › Instructions and Settings › Skills changed; both apply from the next model request.
	setInstructions: async (text: string) => {
		instructionsSettings.text = text;
	},
	setSkills: async (list: SkillInfo[]) => skills.setSkills(list),
	usage: async () => JSON.parse(JSON.stringify(await requireOpen().harness.usage(context))),
	// Entry points outside the chat (App Intents, widget buttons, notification actions); each carries a request ID.
	askFromOutside: (input: OutsideInput) => requireChat().ask(input),
	voiceLine: (input: VoiceLineInput) => requireChat().voiceLine(input),
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

(globalThis as Record<string, unknown>).PiRuntime = { open, ask, submit, settle, entries, close, ...app };
