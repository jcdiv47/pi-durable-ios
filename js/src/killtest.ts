// Kill/resume test fixtures: a scripted model and two slow tools, one replay-safe and one not.
// scripts/kill-test.sh terminates the app while both tools run, relaunches it, and checks that the
// safe tool reran and the unsafe one came back to the model as interrupted.

import type { Context } from "@earendil-works/chord/context";
import { Type } from "@earendil-works/pi-ai";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { defineExtension, defineTool } from "@earendil-works/pi-durable";
import { native } from "./host/native.ts";

function marker(tool: string, event: string, taskId: number): void {
	native.emit(JSON.stringify({ type: "marker", tool, event, taskId, at: Date.now() }));
}

function sleep(ms: number, context: Context): Promise<void> {
	return new Promise((resolve, reject) => {
		const signal = context.abortSignal;
		if (signal?.aborted) return reject(signal.reason);
		const timer = setTimeout(resolve, ms);
		signal?.addEventListener(
			"abort",
			() => {
				clearTimeout(timer);
				reject(signal.reason);
			},
			{ once: true },
		);
	});
}

export function KillTestTools(toolMs: number) {
	const slowLookup = defineTool({
		name: "slow_lookup",
		description: "Look up a value. Slow, read-only, safe to repeat.",
		parameters: Type.Object({ query: Type.String() }),
		replay: "safe",
		execute: async (args, api, context) => {
			marker("slow_lookup", "start", api.taskId);
			await sleep(toolMs, context);
			marker("slow_lookup", "end", api.taskId);
			return { output: [{ type: "text", text: `lookup(${args.query}) = 42` }] };
		},
	});

	const sendMessage = defineTool({
		name: "send_message",
		description: "Send a message. Slow, has an external side effect, must not run twice.",
		parameters: Type.Object({ to: Type.String(), text: Type.String() }),
		execute: async (args, api, context) => {
			marker("send_message", "start", api.taskId);
			await sleep(toolMs, context);
			marker("send_message", "end", api.taskId);
			return { output: [{ type: "text", text: `sent to ${args.to}` }] };
		},
	});

	return defineExtension({ name: "killtest", tools: [slowLookup, sendMessage] });
}

/** Model `faux/killtest`: first calls both tools in one round, then answers with what they returned. */
export function createKillTestFaux() {
	const faux = fauxProvider({ provider: "faux", models: [{ id: "killtest", name: "Kill test" }] });
	const step = (transcript: { messages: { role: string; toolName?: string; isError?: boolean }[] }) => {
		const messages = transcript.messages;
		let lastUser = -1;
		messages.forEach((m, i) => {
			if (m.role === "user") lastUser = i;
		});
		const results = messages.slice(lastUser + 1).filter((m) => m.role === "toolResult");
		if (results.length === 0) {
			return fauxAssistantMessage(
				[fauxToolCall("slow_lookup", { query: "answer" }), fauxToolCall("send_message", { to: "ops", text: "hello" })],
				{ stopReason: "toolUse" },
			);
		}
		return fauxAssistantMessage(`Done: ${results.map((r) => `${r.toolName}=${r.isError ? "error" : "ok"}`).join(", ")}`);
	};
	// Each model request consumes one step; every step is the same function of the transcript.
	faux.setResponses(Array.from({ length: 100 }, () => step as never));
	return faux;
}
