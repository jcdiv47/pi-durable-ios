// Scheduled agent tasks (spec "Durability on iOS": `runtime.sleepUntil` for briefings, reminders and widget
// refreshes). A schedule is a durable task its conversation owns in the background: it sleeps until its next
// time, submits its prompt to the conversation, waits for the answer, optionally posts it as a notification,
// and sleeps again. The sleep is stored, so Swift wakes the app for it (BGAppRefreshTask) through `onWake`.
// Every run's input has the request ID `schedule-<task>-<run>`, so a run a crash interrupts is found again,
// not submitted twice.

import type { JsonValue } from "@earendil-works/chord";
import { bool, obj, opt, str } from "@earendil-works/pi-schema";
import { AssistantEntry, defineDoc, defineExtension, defineTask, defineTool, type EntryRecord, section } from "@earendil-works/pi-durable";
import { hostCall } from "../host/hostcall.ts";

export type ScheduleEntry = {
	taskId: number;
	conversationId: number;
	name: string;
	prompt: string;
	everyMs?: number;
	/** The next run, while the task sleeps. */
	nextAt?: number;
	runs: number;
	lastRunAt?: number;
	lastAnswer?: string;
	notify: boolean;
	/** The tool task that created it, so a rerun after a crash finds it instead of creating another. */
	createdBy: number;
	createdAt: number;
};

/** Every live schedule, across conversations: for the app's Tasks screen and the `RunPiTask` intent. */
export const SchedulesDoc = defineDoc<{ items: ScheduleEntry[] }>({
	kind: "app.schedules",
	version: 1,
	scope: "session",
	initial: () => ({ items: [] }),
	checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 50,
});

/**
 * Inputs that did not come from the chat composer, or carry attachments: the transcript shows where they came from
 * and the attachments (`InputData` in attachments.ts).
 */
export const OriginInput = "app.input";
export type Origin = { origin: string };

export function answerText(entry: EntryRecord | undefined): string {
	const message = (entry?.model as { content?: { type: string; text?: string }[] }[] | undefined)?.[0];
	return (message?.content ?? [])
		.filter((block) => block.type === "text")
		.map((block) => block.text ?? "")
		.join("");
}

const dayMs = 86_400_000;

/** `"30m"`, `"3h"`, `"1d"`, `"1w"` in milliseconds; undefined when it does not parse. */
export function parseInterval(text: string | undefined): number | undefined {
	const match = /^(\d+)\s*(m|min|h|d|w)$/.exec(text?.trim() ?? "");
	if (match === null) return undefined;
	const unit = match[2] === "w" ? 7 * dayMs : match[2] === "d" ? dayMs : match[2] === "h" ? 3_600_000 : 60_000;
	return Number(match[1]) * unit;
}

/**
 * Run `k` of a schedule that first ran at `first`. An interval of whole days steps through the calendar in the device's
 * time zone, so a daily 8:00 stays at 8:00 across daylight saving changes; shorter intervals step in elapsed time.
 */
function slot(first: number, everyMs: number, k: number): number {
	if (everyMs % dayMs !== 0) return first + k * everyMs;
	const date = new Date(first);
	date.setDate(date.getDate() + k * (everyMs / dayMs));
	return date.getTime();
}

/**
 * The next run after the one at `after` that is not before `now`: runs a sleeping app missed are skipped, not caught
 * up. Slots count from the first run, so a daily schedule that an earlier version let drift by an hour at a daylight
 * saving change returns to its first run's time; at least half an interval after `after`, so it does not run twice
 * that day.
 */
export function nextSlot(first: number, everyMs: number, after: number, now: number): number {
	const from = Math.max(after + everyMs / 2, now);
	// An estimate within one slot of the answer: a daylight saving change moves a day's slot by an hour at most.
	let k = Math.max(1, Math.floor((from - first) / everyMs));
	while (k > 1 && slot(first, everyMs, k - 1) >= from) k--;
	while (slot(first, everyMs, k) < from) k++;
	return slot(first, everyMs, k);
}

/** What a scheduled run answers when it has nothing to tell: no notification, and the transcript says so quietly. */
export const NO_REPLY = "NO_REPLY";

export const isNoReply = (text: string) => text.trim() === NO_REPLY;

/** How a `NO_REPLY` answer reads to the user. */
export const noReplyText = "Nothing to report";

/** Schedules repeat at most every 15 minutes; iOS runs background refreshes no more often anyway. */
export const minimumIntervalMs = 15 * 60_000;

type ScheduleInput = { name: string; prompt: string; at: number; everyMs?: number; notify: boolean };
type ScheduleState = { phase: "wait"; at: number; runs: number } | { phase: "run"; at: number; runs: number };

export const ScheduledTask = defineTask<ScheduleInput, ScheduleState, null>({
	name: "app.scheduled",
	version: 1,
	initial: (input) => ({ phase: "wait", at: input.at, runs: 0 }),
	phases: {
		wait: (task, runtime, context) => {
			const { at, runs } = task.state.checkpoint;
			return runtime.sleepUntil(at, { phase: "run", at, runs }, context);
		},
		run: async (task, runtime, context) => {
			const { at, runs } = task.state.checkpoint;
			const { name, prompt, everyMs, notify, at: first } = task.input;
			const conversation = await runtime.conversation(runtime.conversationId, context);
			let answer = "";
			if (conversation !== undefined) {
				// The same request ID after a crash finds this run's input instead of submitting it again.
				const submission = await conversation.submit(
					{
						type: "input",
						content: `[Scheduled task "${name}"] ${prompt}`,
						requestId: `schedule-${task.id}-${runs}`,
						entry: { kind: OriginInput, data: { origin: `Scheduled: ${name}` } },
					},
					context,
				);
				const settled = await submission.wait(context);
				if (settled.status === "done" && settled.type === "input") {
					answer = answerText(await runtime.entry(AssistantEntry, settled.answer, context));
				}
			}
			if (notify && answer.trim() !== "" && !isNoReply(answer)) {
				// The notification identifier makes a rerun replace it rather than post a second one.
				await hostCall(
					"notify.post",
					{ id: `schedule-${task.id}-${runs}`, title: `Pi · ${name}`, body: answer.slice(0, 400), conversationId: runtime.conversationId },
					runtime.signal,
				);
			}
			const now = runtime.now();
			const next = everyMs === undefined || conversation === undefined ? undefined : nextSlot(first, everyMs, at, now);
			await runtime.commit(async (tx) => {
				const index = await tx.doc(SchedulesDoc);
				const position = index.items.findIndex((item) => item.taskId === task.id);
				if (next === undefined) {
					if (position >= 0) index.items.splice(position, 1);
					return { status: "terminal", outcome: { status: "completed", result: null } };
				}
				const entry = index.items[position];
				if (entry !== undefined) {
					entry.runs = runs + 1;
					entry.lastRunAt = now;
					entry.lastAnswer = isNoReply(answer) ? noReplyText : answer.slice(0, 400);
					entry.nextAt = next;
				}
				return { status: "sleeping", until: next, checkpoint: { phase: "run", at: next, runs: runs + 1 } };
			}, context);
		},
	},
	abort: (task, runtime, context) =>
		runtime.commit(async (tx) => {
			const index = await tx.doc(SchedulesDoc);
			const position = index.items.findIndex((item) => item.taskId === task.id);
			if (position >= 0) index.items.splice(position, 1);
			return { status: "terminal", outcome: { status: "aborted" } };
		}, context),
});

function json(value: unknown) {
	return { output: [{ type: "text" as const, text: JSON.stringify(value, null, 1) }] };
}

function failure(message: string) {
	return { output: [{ type: "text" as const, text: message }], isError: true };
}

const isoDate = (description: string) => str({ description: `${description}, ISO 8601 with a UTC offset` });

function describe(entry: ScheduleEntry) {
	return {
		name: entry.name,
		prompt: entry.prompt,
		every: entry.everyMs === undefined ? "once" : entry.everyMs % dayMs === 0 ? `${entry.everyMs / dayMs} days` : `${Math.round(entry.everyMs / 60_000)} minutes`,
		next: entry.nextAt === undefined ? undefined : new Date(entry.nextAt).toISOString(),
		runs: entry.runs,
		notify: entry.notify,
	};
}

/**
 * The schedule tools. `abortTask` is the Harness's: a tool cannot abort a task it does not own, and a schedule
 * belongs to its conversation.
 */
export function ScheduleTools(abortTask: (taskId: number) => Promise<unknown>) {
	const scheduleTask = defineTool({
		name: "schedule_task",
		description:
			"Run a prompt in this conversation later, once (`at`) or repeatedly (`every`: 30m, 3h, 1d, 1w; at least 15m), even while the app is closed. " +
			"Days and weeks keep the local time of day of the first run, across daylight saving changes. " +
			"Use it to refresh $doc values widgets show (the prompt says which set_value to call), or for briefings. " +
			"iOS runs it at or after the time, not exactly on it. `notify` posts the answer as a notification. The user may be asked to approve.",
		parameters: obj({
			name: str({ description: "Short and unique in this conversation, e.g. nudge" }),
			prompt: str({ description: "What to do on each run, written to yourself" }),
			at: opt(isoDate("First run; omitted: one interval from now")),
			every: opt(str({ description: "Repeat interval; omitted: run once" })),
			notify: opt(bool({ description: `Post each answer as a notification (default false); a run that answers exactly ${NO_REPLY} posts none` })),
		}),
		replay: "safe",
		execute: async (args, api, context) => {
			const everyMs = parseInterval(args.every);
			if (args.every !== undefined && everyMs === undefined) return failure(`every must look like 30m, 3h or 1d, not ${args.every}`);
			if (everyMs !== undefined && everyMs < minimumIntervalMs) return failure("every must be at least 15m");
			const at = args.at === undefined ? undefined : Date.parse(args.at);
			if (at !== undefined && Number.isNaN(at)) return failure(`at is not an ISO 8601 date: ${args.at}`);
			if (at === undefined && everyMs === undefined) return failure("Give at, every, or both");
			const now = api.now();
			const first = at ?? now + everyMs!;
			if (first < now - 60_000 && everyMs === undefined) return failure(`at is in the past: ${args.at}`);
			const outcome = await api.commit(async (tx) => {
				const index = await tx.doc(SchedulesDoc);
				const mine = index.items.find((item) => item.createdBy === api.taskId);
				if (mine !== undefined) return { entry: structuredClone(mine) as ScheduleEntry };
				if (index.items.some((item) => item.conversationId === api.conversationId && item.name === args.name)) {
					return { error: `A task named ${args.name} exists in this conversation; cancel_scheduled_task it first, or pick another name.` };
				}
				// Stored values are strict JSON: an absent interval is left out, not undefined.
				const repeat = everyMs === undefined ? {} : { everyMs };
				const input: ScheduleInput = { name: args.name, prompt: args.prompt, at: first, notify: args.notify ?? false, ...repeat };
				const taskId = await tx.createTask(ScheduledTask, input, {
					ownership: { kind: "conversation" },
					conversationId: api.conversationId,
					// Not part of the conversation's runs: Stop does not cancel it, and idle waits do not wait for it.
					background: true,
				});
				const entry: ScheduleEntry = {
					taskId,
					conversationId: api.conversationId,
					name: args.name,
					prompt: args.prompt,
					...repeat,
					nextAt: first,
					runs: 0,
					notify: input.notify,
					createdBy: api.taskId,
					createdAt: now,
				};
				index.items.push(entry);
				return { entry: structuredClone(entry) };
			}, context);
			if (outcome.entry === undefined) return failure(outcome.error ?? "Could not schedule the task");
			return json({ scheduled: describe(outcome.entry) });
		},
	});

	const listTasks = defineTool({
		name: "list_scheduled_tasks",
		description: "The scheduled tasks of this conversation, with their next run.",
		parameters: obj({}),
		replay: "safe",
		execute: async (_args, api, context) => {
			const items = (await api.snapshot(SchedulesDoc, context))?.items ?? [];
			return json(items.filter((item) => item.conversationId === api.conversationId).map(describe));
		},
	});

	const cancelTask = defineTool({
		name: "cancel_scheduled_task",
		description: "Stop a scheduled task of this conversation.",
		parameters: obj({ name: str() }),
		replay: "safe",
		execute: async (args, api, context) => {
			const items = (await api.snapshot(SchedulesDoc, context))?.items ?? [];
			const entry = items.find((item) => item.conversationId === api.conversationId && item.name === args.name);
			// Gone already: cancelled, or a rerun after the abort finished.
			if (entry === undefined) return json({ cancelled: args.name, note: "no such task (already cancelled?)" });
			await abortTask(entry.taskId);
			return json({ cancelled: args.name });
		},
	});

	const notifySchedule = defineTool({
		name: "notify_schedule",
		description:
			"Show the user a notification at a time, e.g. a reminder. It needs no model run, so it arrives on time even if the app is closed. " +
			"The same id replaces an earlier notification; omit it for a new one. Tapping it opens this conversation.",
		parameters: obj({
			title: str(),
			body: str(),
			at: isoDate("When to show it"),
			id: opt(str({ description: "Letters, digits and _; reuse it to change or replace the notification" })),
		}),
		replay: "safe",
		execute: async (args, api, context) => {
			const at = Date.parse(args.at);
			if (Number.isNaN(at)) return failure(`at is not an ISO 8601 date: ${args.at}`);
			if (args.id !== undefined && !/^[A-Za-z0-9_]+$/.test(args.id)) return failure("id may use only letters, digits and _");
			// The identifier is the idempotency key: a rerun schedules the same notification again, replacing it.
			const identifier = `pi-c${api.conversationId}-${args.id ?? `t${api.taskId}`}`;
			const result = await hostCall<JsonValue>(
				"notify.schedule",
				{ identifier, title: args.title, body: args.body, at, conversationId: api.conversationId },
				context.abortSignal,
			);
			return json(result);
		},
	});

	const scheduleSection = section("schedule", () =>
		[
			"You can act later: schedule_task runs a prompt in this conversation once or repeatedly, even while the app is closed, and notify_schedule shows a reminder at a time.",
			"Runs from a schedule start with [Scheduled task \"name\"]; do what the prompt says, keep the answer short, and update the $doc values it names.",
			`When a scheduled run has nothing worth telling the user (for example, a check found no change), answer exactly ${NO_REPLY}: no notification is posted.`,
		].join("\n"),
	);

	return defineExtension({
		name: "tasks",
		sections: [scheduleSection],
		tools: [scheduleTask, listTasks, cancelTask, notifySchedule],
		tasks: [ScheduledTask],
	});
}

/** Tool names with what they do, for the approval settings screen. */
export const scheduleToolInfo = ScheduleTools(async () => undefined).tools!.map((tool) => ({ name: tool.name, description: tool.description }));
