// Apple tools: JS stubs whose work happens in Swift (Packages/PiAppleTools) through `hostCall`.
// Reads are replay-safe. calendar_create_event and reminders_create are replay-safe too: Swift tags the item with the
// tool task's ID and finds it instead of creating a second one when a crash makes the call run again.
// reminders_complete sets a state, so running it twice is the same as once.

import { bool, lit, num, obj, opt, str, union } from "@earendil-works/pi-schema";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import { hostCall } from "../host/hostcall.ts";

function json(value: unknown) {
	return { output: [{ type: "text" as const, text: JSON.stringify(value, null, 1) }] };
}

const isoDate = (description: string) => str({ description: `${description}, ISO 8601 with a UTC offset` });

const calendarQuery = defineTool({
	name: "calendar_query",
	description: "List calendar events that overlap a time range, optionally filtered by text in the title, location or notes.",
	parameters: obj({
		start: isoDate("Range start"),
		end: isoDate("Range end"),
		search: opt(str({ description: "Case-insensitive text to match" })),
		limit: opt(num({ description: "Maximum events to return (default 50)" })),
	}),
	replay: "safe",
	execute: async (args, _api, context) => json(await hostCall("calendar.query", args, context.abortSignal)),
});

const remindersQuery = defineTool({
	name: "reminders_query",
	description: "List reminders. By default only incomplete ones; optionally only those due before a date, or in one list.",
	parameters: obj({
		includeCompleted: opt(bool()),
		dueBefore: opt(isoDate("Only reminders due before this")),
		list: opt(str({ description: "Exact reminder list name; use listId when names are ambiguous" })),
		listId: opt(str({ description: "List ID from reminders_lists; use either list or listId" })),
		limit: opt(num({ description: "Maximum reminders to return (default 50)" })),
	}),
	replay: "safe",
	execute: async (args, _api, context) => json(await hostCall("reminders.query", args, context.abortSignal)),
});

const calendarCreateEvent = defineTool({
	name: "calendar_create_event",
	description: "Create a calendar event in the default calendar. The user may be asked to approve it first.",
	parameters: obj({
		title: str(),
		start: isoDate("Start"),
		end: isoDate("End"),
		allDay: opt(bool()),
		location: opt(str()),
		notes: opt(str()),
	}),
	replay: "safe",
	execute: async (args, api, context) =>
		json(await hostCall("calendar.createEvent", { ...args, idempotencyKey: `task-${api.taskId}` }, context.abortSignal)),
});

const remindersCreate = defineTool({
	name: "reminders_create",
	description: "Add a reminder, by default to the default list. The user may be asked to approve it first.",
	parameters: obj({
		title: str(),
		due: opt(
			str({ description: "When it is due: an ISO 8601 date-time with a UTC offset (alerts then), or a date YYYY-MM-DD (no alert)" }),
		),
		list: opt(str({ description: "Exact reminder list name; use listId when names are ambiguous" })),
		listId: opt(str({ description: "List ID from reminders_lists; use either list or listId" })),
		notes: opt(str()),
		priority: opt(union([lit("none"), lit("low"), lit("medium"), lit("high")])),
	}),
	replay: "safe",
	execute: async (args, api, context) =>
		json(await hostCall("reminders.create", { ...args, idempotencyKey: `task-${api.taskId}` }, context.abortSignal)),
});

const remindersLists = defineTool({
	name: "reminders_lists",
	description: "List Apple Reminders lists with IDs, account names and whether they are writable. Use IDs to distinguish lists with the same name.",
	parameters: obj({}),
	replay: "safe",
	execute: async (args, _api, context) => json(await hostCall("reminders.lists", args, context.abortSignal)),
});

const remindersUpdate = defineTool({
	name: "reminders_update",
	description: "Edit a reminder or move it to an existing list. First query the source list for current reminder IDs; use reminders_lists for destination list IDs. Omitted fields stay unchanged; notes: empty string clears notes. Setting due replaces time-based alarms (date-time adds one, date-only adds none); clearDue removes the deadline and time-based alarms. Location alarms are preserved. Cannot reorder reminders within a list. Requires approval by default. If interrupted, query again to check whether the change took effect before retrying.",
	parameters: obj({
		id: str({ description: "Current reminder ID from reminders_query" }),
		title: opt(str()),
		notes: opt(str()),
		priority: opt(union([lit("none"), lit("low"), lit("medium"), lit("high")])),
		due: opt(str({ description: "ISO 8601 date-time with UTC offset, or YYYY-MM-DD" })),
		clearDue: opt(bool()),
		list: opt(str({ description: "Destination list's exact name; use either list or listId" })),
		listId: opt(str({ description: "Destination list ID from reminders_lists" })),
	}),
	// A move may change the EventKit identifier. Do not blindly replay after an interrupted save.
	execute: async (args, _api, context) => json(await hostCall("reminders.update", args, context.abortSignal)),
});

const remindersComplete = defineTool({
	name: "reminders_complete",
	description: "Mark a reminder done, or not done with completed: false. Takes the id from reminders_query.",
	parameters: obj({
		id: str({ description: "The reminder's id" }),
		completed: opt(bool({ description: "Default true" })),
	}),
	replay: "safe",
	execute: async (args, _api, context) => json(await hostCall("reminders.complete", args, context.abortSignal)),
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
		"`interval` splits the range into days or hours. The first Health read asks the user for permission for all of these metrics in one sheet.",
	parameters: obj({
		metric: union(healthMetrics.map((m) => lit(m))),
		start: isoDate("Range start"),
		end: isoDate("Range end"),
		interval: opt(union([lit("total"), lit("day"), lit("hour")])),
	}),
	replay: "safe",
	execute: async (args, _api, context) => json(await hostCall("health.query", args, context.abortSignal)),
});

const locationCurrent = defineTool({
	name: "location_current",
	description:
		"The iPhone's current location: coordinates, accuracy and, unless placeName is false, the address and city. " +
		"Only when the user's request needs it (weather, nearby places, travel time). The first call asks the user for permission.",
	parameters: obj({
		placeName: opt(bool({ description: "Look up the address too (default true)" })),
	}),
	replay: "safe",
	execute: async (args, _api, context) => json(await hostCall("location.current", args, context.abortSignal)),
});

const photosSearch = defineTool({
	name: "photos_search",
	description:
		"Search the user's photo library by what the photos show (\"whiteboard with a diagram\", \"receipt from a ramen place\", \"my bike\"), " +
		"with an on-device image model. Returns the best matches' IDs, dates and similarity scores; the user sees them as thumbnails. " +
		"You never see the photos, so describe what you searched for, not what they show. Scores above about 0.25 are usually good matches. " +
		"The first call asks the user for permission.",
	parameters: obj({
		query: str({ description: "What the photos show, as a short description in English" }),
		from: opt(isoDate("Only photos taken at or after this")),
		to: opt(isoDate("Only photos taken before this")),
		favoritesOnly: opt(bool()),
		screenshotsOnly: opt(bool()),
		limit: opt(num({ description: "Maximum matches (default 8, at most 24)" })),
	}),
	replay: "safe",
	execute: async (args, _api, context) => json(await hostCall("photos.search", args, context.abortSignal)),
});

const currentTime = defineTool({
	name: "current_time",
	description: "The current local date and time, with the time zone.",
	parameters: obj({}),
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
		"Use the Apple tools to read the user's calendar, reminders and health data and to find photos when it helps, and to add events and reminders when asked. Call current_time when the exact time matters.",
		"Keep answers short; they are read on a phone.",
	].join("\n");
});

export const AppleTools = defineExtension({
	name: "apple",
	sections: [contextSection],
	tools: [currentTime, locationCurrent, photosSearch, calendarQuery, remindersQuery, calendarCreateEvent, remindersCreate, remindersLists, remindersUpdate, remindersComplete, healthQuery],
});

/** Tool names with what they do, for the approval settings screen. */
export const appleToolInfo = AppleTools.tools!.map((tool) => ({ name: tool.name, description: tool.description }));
