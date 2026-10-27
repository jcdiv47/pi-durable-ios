// Apple tools: JS stubs whose work happens in Swift (Packages/PiAppleTools) through `hostCall`.
// Reads are replay-safe. calendar_create_event is replay-safe too: Swift tags the event with the tool
// task's ID and finds it instead of creating a second one when a crash makes the call run again.

import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import { hostCall } from "../host/hostcall.ts";

function json(value: unknown) {
	return { output: [{ type: "text" as const, text: JSON.stringify(value, null, 1) }] };
}

const isoDate = (description: string) => Type.String({ description: `${description}, ISO 8601 with a UTC offset` });

const calendarQuery = defineTool({
	name: "calendar_query",
	description: "List calendar events that overlap a time range, optionally filtered by text in the title, location or notes.",
	parameters: Type.Object({
		start: isoDate("Range start"),
		end: isoDate("Range end"),
		search: Type.Optional(Type.String({ description: "Case-insensitive text to match" })),
		limit: Type.Optional(Type.Number({ description: "Maximum events to return (default 50)" })),
	}),
	replay: "safe",
	execute: async (args, _api, context) => json(await hostCall("calendar.query", args, context.abortSignal)),
});

const remindersQuery = defineTool({
	name: "reminders_query",
	description: "List reminders. By default only incomplete ones; optionally only those due before a date, or in one list.",
	parameters: Type.Object({
		includeCompleted: Type.Optional(Type.Boolean()),
		dueBefore: Type.Optional(isoDate("Only reminders due before this")),
		list: Type.Optional(Type.String({ description: "Reminder list name" })),
		limit: Type.Optional(Type.Number({ description: "Maximum reminders to return (default 50)" })),
	}),
	replay: "safe",
	execute: async (args, _api, context) => json(await hostCall("reminders.query", args, context.abortSignal)),
});

const calendarCreateEvent = defineTool({
	name: "calendar_create_event",
	description: "Create a calendar event in the default calendar. The user may be asked to approve it first.",
	parameters: Type.Object({
		title: Type.String(),
		start: isoDate("Start"),
		end: isoDate("End"),
		allDay: Type.Optional(Type.Boolean()),
		location: Type.Optional(Type.String()),
		notes: Type.Optional(Type.String()),
	}),
	replay: "safe",
	execute: async (args, api, context) =>
		json(await hostCall("calendar.createEvent", { ...args, idempotencyKey: `task-${api.taskId}` }, context.abortSignal)),
});

const healthMetrics = [
	"steps",
	"activeEnergy",
	"distanceWalkingRunning",
	"flightsClimbed",
	"heartRate",
	"restingHeartRate",
	"bodyMass",
	"sleep",
] as const;

const healthQuery = defineTool({
	name: "health_query",
	description:
		"Read Apple Health data for a time range. Cumulative metrics (steps, activeEnergy kcal, distanceWalkingRunning m, flightsClimbed) are summed; " +
		"heartRate and restingHeartRate (bpm) and bodyMass (kg) are averaged with min and max; sleep gives hours asleep. " +
		"`interval` splits the range into days or hours. The user is asked for permission the first time a metric is read.",
	parameters: Type.Object({
		metric: Type.Union(healthMetrics.map((m) => Type.Literal(m))),
		start: isoDate("Range start"),
		end: isoDate("Range end"),
		interval: Type.Optional(Type.Union([Type.Literal("total"), Type.Literal("day"), Type.Literal("hour")])),
	}),
	replay: "safe",
	execute: async (args, _api, context) => json(await hostCall("health.query", args, context.abortSignal)),
});

const currentTime = defineTool({
	name: "current_time",
	description: "The current local date and time, with the time zone.",
	parameters: Type.Object({}),
	replay: "safe",
	execute: async () => json(now()),
});

function now() {
	const date = new Date();
	const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
	const offset = -date.getTimezoneOffset();
	const sign = offset >= 0 ? "+" : "-";
	const pad = (n: number) => String(Math.floor(Math.abs(n))).padStart(2, "0");
	const local = new Date(date.getTime() + offset * 60_000).toISOString().slice(0, 19);
	return {
		local: `${local}${sign}${pad(offset / 60)}:${pad(offset % 60)}`,
		weekday: date.toLocaleDateString("en-US", { weekday: "long", timeZone }),
		timeZone,
	};
}

/** Changes once a day, so the prompt stays cache-friendly; the model calls current_time for the time. */
const contextSection = section("context", () => {
	const { local, weekday, timeZone } = now();
	return [
		"You are Pi, a personal assistant running on the user's iPhone.",
		`Today is ${weekday}, ${local.slice(0, 10)}. Time zone: ${timeZone}.`,
		"Use the Apple tools to read the user's calendar, reminders and health data when it helps. Call current_time when the exact time matters.",
		"Keep answers short; they are read on a phone.",
	].join("\n");
});

export const AppleTools = defineExtension({
	name: "apple",
	sections: [contextSection],
	tools: [currentTime, calendarQuery, remindersQuery, calendarCreateEvent, healthQuery],
});

/** Tool names with what they do, for the approval settings screen. */
export const appleToolInfo = AppleTools.tools!.map((tool) => ({ name: tool.name, description: tool.description }));
