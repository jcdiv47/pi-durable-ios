// Approval gate for sensitive tools: a `beforeTool` hook that, per the tool's policy, lets a call run,
// blocks it, or asks the user. The answer is stored with the tool task's `memo`, so once given it
// survives a restart. A call still waiting when the process dies runs its hook again on resume and asks
// again: the conversation waits durably until the user answers (or aborts the run).

import type { Context } from "@earendil-works/chord/context";
import type { JsonObject } from "@earendil-works/pi-ai";
import { defineExtension, hook, ToolTask } from "@earendil-works/pi-durable";

export type ToolPolicy = "auto" | "ask" | "deny";
export type Decision = "allow" | "deny";

export type ApprovalRequest = {
	/** The tool task's ID; unique per call and stable across restarts. */
	readonly id: number;
	readonly conversationId: number;
	/** The model's tool call ID, which the transcript shows the call under. */
	readonly callId: string;
	readonly tool: string;
	readonly arguments: JsonObject;
	readonly requestedAt: number;
};

/** Tools that ask by default: writes the user should see first. */
export const defaultPolicies: Record<string, ToolPolicy> = {
	calendar_create_event: "ask",
	reminders_create: "ask",
	reminders_update: "ask",
	alarms_set: "ask",
	publish_surface: "ask",
	// A schedule runs the model unattended, on the user's key.
	schedule_task: "ask",
	// A page could use it to send data out; URLs the conversation already holds run without asking (`trusted`).
	web_fetch: "ask",
	// A shell on the user's machines. A host set to "Run without asking" skips this while the conversation holds no
	// outside text (`trusted`, ssh.ts).
	ssh_exec: "ask",
};

/** A call of an "ask" tool that may run without asking. */
export type TrustCheck = (args: JsonObject, conversationId: number, context: Context) => Promise<boolean>;

export class Approvals {
	policies: Record<string, ToolPolicy> = { ...defaultPolicies };
	/** Per tool: calls its policy "ask" lets run without asking. */
	trusted: Record<string, TrustCheck> = {};
	/** Defaults of tools that come and go (MCP servers' tools), for those without a stored policy. */
	dynamicDefaults: () => Record<string, ToolPolicy> = () => ({});
	readonly #waiting = new Map<number, { request: ApprovalRequest; answer: (decision: Decision) => void }>();
	/**
	 * Answers that came before their request: a notification action launches the app, and its answer can arrive
	 * before `resume()` reruns the hook that asks again.
	 */
	readonly #early = new Map<number, Decision>();

	constructor(private readonly changed: (pending: ApprovalRequest[]) => void) {}

	policy(tool: string): ToolPolicy {
		return this.policies[tool] ?? this.dynamicDefaults()[tool] ?? "auto";
	}

	pending(): ApprovalRequest[] {
		return [...this.#waiting.values()].map((w) => w.request);
	}

	/**
	 * Answers a waiting request. False when nothing waits under `id` yet; the answer is then kept for the hook, in
	 * case it is about to ask again (an answered or aborted request never asks again, so it is never used).
	 */
	answer(id: number, decision: Decision): boolean {
		const waiting = this.#waiting.get(id);
		if (waiting === undefined) {
			this.#early.set(id, decision);
			return false;
		}
		waiting.answer(decision);
		return true;
	}

	#ask(request: ApprovalRequest, context: Context): Promise<Decision> {
		return new Promise<Decision>((resolve, reject) => {
			const signal = context.abortSignal;
			const done = () => {
				this.#waiting.delete(request.id);
				signal?.removeEventListener("abort", onAbort);
				this.changed(this.pending());
			};
			const onAbort = () => {
				done();
				reject(signal?.reason ?? new Error("aborted"));
			};
			if (signal?.aborted) return reject(signal.reason);
			signal?.addEventListener("abort", onAbort, { once: true });
			this.#waiting.set(request.id, {
				request,
				answer: (decision) => {
					done();
					resolve(decision);
				},
			});
			this.changed(this.pending());
		});
	}

	extension() {
		return defineExtension({
			name: "approvals",
			hooks: [
				hook(ToolTask, {
					beforeTool: async (call, api, context) => {
						const policy = this.policy(call.name);
						if (policy === "auto") return undefined;
						if (policy === "deny") return { block: `The user has turned off ${call.name}.` };
						const trusted = this.trusted[call.name];
						if (trusted !== undefined && (await trusted(call.arguments, api.conversationId, context))) return undefined;
						let decision = await api.memo<Decision>("approval", context);
						if (decision === undefined) {
							const early = this.#early.get(api.taskId);
							this.#early.delete(api.taskId);
							const answered = early ?? await this.#ask(
								{
									id: api.taskId,
									conversationId: api.conversationId,
									callId: call.id,
									tool: call.name,
									arguments: call.arguments,
									requestedAt: Date.now(),
								},
								context,
							);
							decision = await api.memo<Decision>("approval", answered, context);
						}
						return decision === "allow" ? undefined : { block: "The user declined this action." };
					},
				}),
			],
		});
	}
}
