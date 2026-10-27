// UI tools (spec "Agent-facing UI tools"): the agent designs widgets and chat cards as JSON specs. Specs
// live in a rewindable conversation document, so every create or patch is a commit, a fork sees the specs
// as of its fork point, and old versions stay readable. The catalog, validator and renderer are Swift's
// (PiUI's `SurfaceHost`, through `hostCall`): this file stores specs and Swift checks, draws and exports them.

import type { JsonValue } from "@earendil-works/chord";
import type { Context } from "@earendil-works/chord/context";
import { Type } from "@earendil-works/pi-ai";
import { defineDoc, defineExtension, defineTool, section, type ToolExecutionApi } from "@earendil-works/pi-durable";
import { hostCall } from "../host/hostcall.ts";
import { applyPatch, type PatchOperation } from "./jsonpatch.ts";

type JsonObject = { [key: string]: JsonValue };

export type SurfaceRecord = {
	id: string;
	version: number;
	spec: JsonObject;
	createdAt: number;
	updatedAt: number;
	/** The tool task that created it, so a rerun after a crash finds it instead of creating another. */
	createdBy: number;
	/** Tool tasks whose patches are applied (the newest few), so a rerun does not apply its patch twice. */
	patchedBy: number[];
	published?: { publishedId: string; version: number; at: number };
};

export const SurfacesDoc = defineDoc<{ items: Record<string, SurfaceRecord>; next: number }>({
	kind: "ui.surfaces",
	version: 1,
	scope: "conversation",
	history: "rewindable",
	fork: "asOf",
	initial: () => ({ items: {}, next: 1 }),
	checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 20,
});

/** Values `$doc.<key>` bindings read; exported to `snapshots/values.json` for the widget. */
export const ValuesDoc = defineDoc<{ values: Record<string, JsonValue> }>({
	kind: "ui.values",
	version: 1,
	scope: "session",
	initial: () => ({ values: {} }),
	checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 50,
});

export type PublishedEntry = {
	publishedId: string;
	conversationId: number;
	surfaceId: string;
	version: number;
	title: string;
	families: string[];
	publishedAt: number;
};

/** What is on the Home and Lock Screen, across conversations. */
export const PublishedDoc = defineDoc<{ items: PublishedEntry[] }>({
	kind: "ui.published",
	version: 1,
	scope: "session",
	initial: () => ({ items: [] }),
	checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 50,
});

type Report = { errors: { path: string; message: string }[]; warnings: { path: string; message: string }[]; permissions: string[] };

/** Widget files are per conversation: a fork that edits a shared surface publishes its own copy. */
export const publishedIdOf = (conversationId: number, surfaceId: string) => `c${conversationId}-${surfaceId}`;

function text(value: unknown, details?: JsonValue) {
	return { output: [{ type: "text" as const, text: JSON.stringify(value, null, 1) }], details };
}

function failure(message: string, details?: JsonValue) {
	return { output: [{ type: "text" as const, text: message }], isError: true, details };
}

/** Models sometimes send JSON as a string; accept it. */
function parseJson(value: unknown): unknown {
	if (typeof value !== "string") return value;
	try {
		return JSON.parse(value);
	} catch {
		return value;
	}
}

async function docKeys(api: ToolExecutionApi, context: Context): Promise<string[]> {
	return Object.keys((await api.snapshot(ValuesDoc, context))?.values ?? {});
}

async function values(api: ToolExecutionApi, context: Context): Promise<Record<string, JsonValue>> {
	return { ...((await api.snapshot(ValuesDoc, context))?.values ?? {}) };
}

async function validate(spec: JsonObject, api: ToolExecutionApi, context: Context): Promise<Report> {
	return hostCall<Report>("ui.validate", { spec, docKeys: await docKeys(api, context) }, context.abortSignal);
}

async function record(api: ToolExecutionApi, id: string, context: Context): Promise<SurfaceRecord | undefined> {
	return (await api.snapshot(SurfacesDoc, api.conversationId, context))?.items[id];
}

/** What a UI tool result carries for the app: the chat shows the surface under the call. */
function surfaceDetails(api: ToolExecutionApi, surface: SurfaceRecord): JsonValue {
	return { surface: { conversationId: api.conversationId, id: surface.id, version: surface.version, spec: surface.spec } };
}

function summary(surface: SurfaceRecord, report: Report) {
	return {
		id: surface.id,
		version: surface.version,
		valid: report.errors.length === 0,
		errors: report.errors.map((e) => `${e.path}: ${e.message}`),
		warnings: report.warnings.map((w) => `${w.path}: ${w.message}`),
		permissions: report.permissions,
	};
}

const families = Type.Optional(Type.Array(Type.String(), { description: "Widget families; omitted: all of the spec's" }));

const listComponents = defineTool({
	name: "list_components",
	description: "The surface spec format, each family's slots and design level, the components with their props, and the data sources. Call it before designing a surface.",
	parameters: Type.Object({ families }),
	replay: "safe",
	execute: async (args, _api, context) => {
		const catalog = await hostCall<{ text: string }>("ui.catalog", { families: args.families ?? [] }, context.abortSignal);
		return { output: [{ type: "text", text: catalog.text }] };
	},
});

const createSurface = defineTool({
	name: "create_surface",
	description:
		"Create a surface from a spec: a widget (Home Screen / Lock Screen) or a card shown in this chat. Returns its id and version, " +
		"with errors to fix (patch_surface) and layout warnings. It is stored even when invalid; publishing needs it valid.",
	parameters: Type.Object({
		spec: Type.Record(Type.String(), Type.Unknown(), { description: "The spec (see list_components)" }),
	}),
	prepareArguments: (args) => {
		const input = (args ?? {}) as Record<string, unknown>;
		return { ...input, spec: parseJson(input.spec) } as never;
	},
	replay: "safe",
	execute: async (args, api, context) => {
		const now = Date.now();
		const spec = { schema: 1, ...(args.spec as JsonObject) } as JsonObject;
		const surface = await api.commit(async (tx) => {
			const doc = await tx.doc(SurfacesDoc, api.conversationId);
			const existing = Object.values(doc.items).find((item) => item.createdBy === api.taskId);
			if (existing !== undefined) return structuredClone(existing) as SurfaceRecord;
			const id = `s${doc.next}`;
			doc.next += 1;
			const created: SurfaceRecord = { id, version: 1, spec, createdAt: now, updatedAt: now, createdBy: api.taskId, patchedBy: [] };
			doc.items[id] = created;
			return structuredClone(created);
		}, context);
		const report = await validate(surface.spec, api, context);
		return text(summary(surface, report), surfaceDetails(api, surface));
	},
});

const patchSurface = defineTool({
	name: "patch_surface",
	description:
		"Change a surface with a JSON Patch (RFC 6902; paths like /slots/0/goal, /slots/- to append). baseVersion must be the version you last saw; " +
		"a mismatch fails with the current spec. Returns the new version with errors and warnings.",
	parameters: Type.Object({
		id: Type.String(),
		baseVersion: Type.Number(),
		patch: Type.Array(
			Type.Object({
				op: Type.Union(["add", "remove", "replace", "move", "copy", "test"].map((op) => Type.Literal(op))),
				path: Type.String(),
				value: Type.Optional(Type.Unknown()),
				from: Type.Optional(Type.String()),
			}),
		),
	}),
	prepareArguments: (args) => {
		const input = (args ?? {}) as Record<string, unknown>;
		return { ...input, patch: parseJson(input.patch) } as never;
	},
	replay: "safe",
	execute: async (args, api, context) => {
		const outcome = await api.commit(async (tx) => {
			const doc = await tx.doc(SurfacesDoc, api.conversationId);
			const surface = doc.items[args.id];
			if (surface === undefined) return { error: `No surface ${args.id}. Surfaces: ${Object.keys(doc.items).join(", ") || "none"}` };
			if (surface.patchedBy.includes(api.taskId)) return { surface: structuredClone(surface) as SurfaceRecord };
			if (surface.version !== args.baseVersion) {
				return { error: `Version conflict: ${args.id} is at version ${surface.version}, not ${args.baseVersion}. Current spec: ${JSON.stringify(surface.spec)}` };
			}
			let spec: JsonObject;
			try {
				spec = applyPatch(structuredClone(surface.spec) as JsonObject, args.patch as PatchOperation[]);
			} catch (error) {
				return { error: `The patch does not apply: ${error instanceof Error ? error.message : String(error)}` };
			}
			if (typeof spec !== "object" || spec === null || Array.isArray(spec)) return { error: "The patched spec must stay an object" };
			surface.spec = spec;
			surface.version += 1;
			surface.updatedAt = Date.now();
			surface.patchedBy = [...surface.patchedBy, api.taskId].slice(-20);
			return { surface: structuredClone(surface) as SurfaceRecord };
		}, context);
		if (outcome.surface === undefined) return failure(outcome.error ?? "Patch failed");
		const report = await validate(outcome.surface.spec, api, context);
		return text(summary(outcome.surface, report), surfaceDetails(api, outcome.surface));
	},
});

const bindData = defineTool({
	name: "bind_data",
	description:
		"Bind a prop to a data source the widget resolves itself, e.g. path /slots/0/value to $health.stepsToday. Checks that the source exists, " +
		"asks the user for the permission it needs (the first time), and returns the current value.",
	parameters: Type.Object({
		id: Type.String(),
		path: Type.String({ description: "JSON Pointer of the prop, e.g. /slots/0/value" }),
		source: Type.String({ description: "e.g. $health.stepsToday, $calendar.next.title, $doc.nudge" }),
	}),
	replay: "safe",
	execute: async (args, api, context) => {
		const source = args.source.startsWith("$") ? args.source : `$${args.source}`;
		const info = await hostCall<{ exists: boolean; known?: string[]; authorization?: string; value?: JsonValue }>(
			"ui.source",
			{ source },
			context.abortSignal,
		);
		if (!info.exists) return failure(`Unknown source ${source}. Sources: ${(info.known ?? []).join(", ")}, or $doc.<key>`);
		const outcome = await api.commit(async (tx) => {
			const doc = await tx.doc(SurfacesDoc, api.conversationId);
			const surface = doc.items[args.id];
			if (surface === undefined) return { error: `No surface ${args.id}` };
			if (!surface.patchedBy.includes(api.taskId)) {
				try {
					surface.spec = applyPatch(structuredClone(surface.spec) as JsonObject, [{ op: "add", path: args.path, value: source }]);
				} catch (error) {
					return { error: `Cannot bind ${args.path}: ${error instanceof Error ? error.message : String(error)}` };
				}
				surface.version += 1;
				surface.updatedAt = Date.now();
				surface.patchedBy = [...surface.patchedBy, api.taskId].slice(-20);
			}
			return { surface: structuredClone(surface) as SurfaceRecord };
		}, context);
		if (outcome.surface === undefined) return failure(outcome.error ?? "Binding failed");
		const report = await validate(outcome.surface.spec, api, context);
		return text(
			{ ...summary(outcome.surface, report), source, authorization: info.authorization, currentValue: info.value ?? null },
			surfaceDetails(api, outcome.surface),
		);
	},
});

const validateSurface = defineTool({
	name: "validate_surface",
	description: "Check a surface against the components, its families' slot limits and design levels. Lists errors to fix and layout warnings.",
	parameters: Type.Object({ id: Type.String() }),
	replay: "safe",
	execute: async (args, api, context) => {
		const surface = await record(api, args.id, context);
		if (surface === undefined) return failure(`No surface ${args.id}`);
		return text(summary(surface, await validate(surface.spec, api, context)));
	},
});

const previewSurface = defineTool({
	name: "preview_surface",
	description:
		"Render a surface to PNG images, as the iPhone would show it, with the user's current data, plus layout warnings (overflow). " +
		"Look at them to check your work. Lock Screen families render once (tinted); others in each requested appearance.",
	parameters: Type.Object({
		id: Type.String(),
		families,
		appearances: Type.Optional(Type.Array(Type.Union([Type.Literal("light"), Type.Literal("dark"), Type.Literal("tinted")]), { description: "Default light" })),
	}),
	replay: "safe",
	execute: async (args, api, context) => {
		const surface = await record(api, args.id, context);
		if (surface === undefined) return failure(`No surface ${args.id}`);
		// A text-only model would get placeholders; skip the rendering and keep the layout checks.
		const ref = (await api.agent(context)).model;
		const vision = ref === undefined || api.models.getModels(ref.provider).find((m) => m.id === ref.modelId)?.input.includes("image") !== false;
		const preview = await hostCall<{
			images: { family: string; appearance: string; png: string; width: number; height: number }[];
			warnings: string[];
			missing: string[];
			errors: string[];
		}>(
			"ui.preview",
			{ spec: surface.spec, families: args.families ?? [], appearances: args.appearances ?? [], doc: await values(api, context), images: vision },
			context.abortSignal,
		);
		const notes = {
			id: surface.id,
			version: surface.version,
			images: vision
				? preview.images.map((image) => `${image.family} ${image.appearance} (${image.width}×${image.height} px at 2×)`)
				: "not rendered: this model does not take images; rely on errors and warnings",
			warnings: preview.warnings,
			errors: preview.errors,
			noDataYet: preview.missing.map((source) => `$${source} has no value here (no permission or no data), so it shows a placeholder`),
		};
		return {
			output: [
				{ type: "text", text: JSON.stringify(notes, null, 1) },
				...preview.images.map((image) => ({ type: "image" as const, data: image.png, mimeType: "image/png" })),
			],
			details: surfaceDetails(api, surface),
		};
	},
});

const publishSurface = defineTool({
	name: "publish_surface",
	description:
		"Put a valid widget surface on the Home Screen and Lock Screen: it becomes a choice in the \"Pi\" widget's settings, and widgets " +
		"showing it update. Publishing again updates it. The user may be asked to approve.",
	parameters: Type.Object({ id: Type.String() }),
	replay: "safe",
	execute: async (args, api, context) => {
		const surface = await record(api, args.id, context);
		if (surface === undefined) return failure(`No surface ${args.id}`);
		if (surface.spec.surface === "card") return failure(`${args.id} is a card; it already shows in the chat. Only widgets are published.`);
		const report = await validate(surface.spec, api, context);
		if (report.errors.length > 0) return failure(`Fix these first:\n${report.errors.map((e) => `${e.path}: ${e.message}`).join("\n")}`);
		const publishedId = publishedIdOf(api.conversationId, surface.id);
		// The file first, then the record: a crash in between reruns both, and both are idempotent.
		const published = await hostCall<{ families: string[] }>(
			"ui.publish",
			{ publishedId, conversationId: api.conversationId, surfaceId: surface.id, version: surface.version, spec: surface.spec },
			context.abortSignal,
		);
		const now = Date.now();
		await api.commit(async (tx) => {
			const doc = await tx.doc(SurfacesDoc, api.conversationId);
			const stored = doc.items[surface.id];
			if (stored !== undefined) stored.published = { publishedId, version: surface.version, at: now };
			const index = await tx.doc(PublishedDoc);
			const entry: PublishedEntry = {
				publishedId,
				conversationId: api.conversationId,
				surfaceId: surface.id,
				version: surface.version,
				title: typeof surface.spec.title === "string" ? surface.spec.title : "Pi",
				families: published.families,
				publishedAt: now,
			};
			const at = index.items.findIndex((item) => item.publishedId === publishedId);
			if (at >= 0) index.items[at] = entry;
			else index.items.push(entry);
		}, context);
		return text(
			{
				published: publishedId,
				version: surface.version,
				families: published.families,
				next: "Tell the user to add the Pi widget (long-press the Home Screen or Lock Screen › Edit › Add Widget › Pi) and choose this surface in its settings, if it is not on their screen yet.",
			},
			surfaceDetails(api, surface),
		);
	},
});

const setValue = defineTool({
	name: "set_value",
	description:
		"Store a value that surfaces show through $doc.<key>, e.g. a nudge, a summary or a goal you computed. Widgets showing it update. " +
		"null removes the key.",
	parameters: Type.Object({
		key: Type.String({ description: "Letters, digits and _; e.g. nudge" }),
		value: Type.Unknown(),
	}),
	replay: "safe",
	execute: async (args, api, context) => {
		if (!/^[A-Za-z0-9_]+$/.test(args.key)) return failure("key may use only letters, digits and _");
		const value = parseJson(args.value) as JsonValue;
		const all = await api.commit(async (tx) => {
			const doc = await tx.doc(ValuesDoc);
			if (value === null || value === undefined) delete doc.values[args.key];
			else doc.values[args.key] = value;
			return structuredClone(doc.values) as Record<string, JsonValue>;
		}, context);
		await hostCall("ui.values", { values: all }, context.abortSignal);
		return text({ key: args.key, stored: value ?? null, keys: Object.keys(all) });
	},
});

const surfacesSection = section("surfaces", () =>
	[
		"You can design native UI: Home Screen and Lock Screen widgets, and cards shown in this chat. Widgets are JSON specs drawn by the app, not code.",
		"Call list_components first. Create with create_surface, fix errors with patch_surface, look at preview_surface images before publishing a widget with publish_surface.",
		"Bind live data ($health.*, $calendar.*, $reminders.*) so the widget stays current without you; put text or numbers you compute in $doc values with set_value.",
		"Use a card to show structured answers (a plan, a checklist, stats) right in the chat.",
	].join("\n"),
);

export const SurfaceTools = defineExtension({
	name: "ui.surfaces",
	sections: [surfacesSection],
	tools: [listComponents, createSurface, patchSurface, bindData, validateSurface, previewSurface, publishSurface, setValue],
});

/** Tool names with what they do, for the approval settings screen. */
export const surfaceToolInfo = SurfaceTools.tools!.map((tool) => ({ name: tool.name, description: tool.description }));
