// Newer model lists from pi.dev, as `pi update --models` fetches them for the CLI (pi-coding-agent's
// `withRemoteCatalog`): pi-ai's built-in providers have fixed lists, generated when pi-ai was built. A provider wrapped
// here adds the models of pi.dev's newer list for it to its own. Swift keeps the lists in a file (`modelCatalogs`
// events, `OpenOptions.modelCatalogs`), so the picker has them at launch without the network.

import type { AnyModel, Api, Model, ModelsStore, ModelsStoreEntry, Provider } from "@earendil-works/pi-ai";
import { getModelType } from "@earendil-works/pi-ai/models";
// When pi-ai's built-in lists were generated: pi.dev's list counts only if it is newer. (Imported by path: the
// package's exports don't include it, and `providers/all` would bundle every provider's list.)
import manifest from "../../node_modules/@earendil-works/pi-ai/dist/providers/data/.manifest.json" with { type: "json" };

export const catalogBaseUrl = "https://pi.dev";
/** How long a list counts as fresh, as the CLI's. A forced refresh (Settings) asks anyway. */
export const catalogInterval = 4 * 60 * 60 * 1000;
const builtinGeneratedAt = Date.parse(manifest.generatedAt);

/** The lists by provider ID, as Swift saves them. */
export type CatalogFile = Record<string, ModelsStoreEntry>;

/** pi-ai's store for the lists, kept in memory; `onWrite` hands the whole file to Swift after each change. */
export class CatalogStore implements ModelsStore {
	#entries: CatalogFile = {};
	onWrite: (file: CatalogFile) => void = () => {};

	load(file: CatalogFile): void {
		this.#entries = { ...file };
	}

	async read(providerId: string): Promise<ModelsStoreEntry | undefined> {
		return this.#entries[providerId];
	}

	async write(providerId: string, entry: ModelsStoreEntry): Promise<void> {
		this.#entries = { ...this.#entries, [providerId]: entry };
		this.onWrite(this.#entries);
	}

	async delete(providerId: string): Promise<void> {
		const { [providerId]: _, ...rest } = this.#entries;
		this.#entries = rest;
		this.onWrite(this.#entries);
	}
}

/** Built-in models first; a pi.dev model with the same type and ID replaces one. */
function merge(builtin: readonly AnyModel[], remote: readonly AnyModel[]): AnyModel[] {
	const merged = new Map<string, AnyModel>();
	for (const model of [...builtin, ...remote]) merged.set(`${getModelType(model)}\0${model.id}`, model);
	return [...merged.values()];
}

/**
 * The pi.dev models this build can use: chat models whose API and endpoint one of the provider's own models has.
 * The provider can send only the APIs its built-in models use, and its key reaches only its own hosts.
 */
function usable(provider: Provider, models: readonly unknown[]): AnyModel[] {
	const builtin = provider.getModels();
	const apis = new Set(builtin.map((model) => model.api));
	const baseUrls = new Set(builtin.map((model) => model.baseUrl));
	return models.filter((model): model is AnyModel => {
		if (typeof model !== "object" || model === null) return false;
		const entry = model as Partial<Model<Api>> & { type?: string };
		return (
			typeof entry.id === "string" &&
			(entry.type === undefined || entry.type === "chat") &&
			typeof entry.api === "string" &&
			apis.has(entry.api as never) &&
			typeof entry.baseUrl === "string" &&
			baseUrls.has(entry.baseUrl) &&
			Array.isArray(entry.input) &&
			typeof entry.contextWindow === "number"
		);
	}).map((model) => ({ ...model, provider: provider.id }));
}

function newer(entry: ModelsStoreEntry | undefined): boolean {
	return entry?.lastModified !== undefined && (Number.isNaN(builtinGeneratedAt) || entry.lastModified > builtinGeneratedAt);
}

/** `provider` with pi.dev's newer list for it added to its own, refreshed through pi-ai's `Models.refresh()`. */
export function withRemoteCatalog(provider: Provider): Provider {
	let remote: AnyModel[] = [];
	return {
		...provider,
		getModels: () => merge(provider.getModels(), remote) as never,
		getAllModels: () => merge(provider.getAllModels?.() ?? provider.getModels(), remote) as never,
		refreshModels: async (context) => {
			const stored = context.stored;
			const restored = newer(stored) ? usable(provider, stored!.models) : [];
			if (!(await context.publish({ update: () => (remote = restored) }))) return;
			if (!context.allowNetwork || context.signal.aborted) return;
			if (!context.force && stored?.checkedAt !== undefined && stored.lastModified !== undefined && Date.now() - stored.checkedAt < catalogInterval) {
				return;
			}
			const url = new URL(`/api/models/providers/${encodeURIComponent(provider.id)}`, catalogBaseUrl);
			url.searchParams.set("types", "chat");
			// Revalidate only with a saved list behind the validator, so a 304 never leaves the list empty.
			const etag = stored !== undefined && stored.models.length > 0 ? stored.etag : undefined;
			const response = await fetch(url, {
				headers: { accept: "application/json", ...(etag === undefined ? {} : { "if-none-match": etag }) },
				signal: context.signal,
			});
			if (context.signal.aborted) return;
			const checkedAt = Date.now();
			if (response.status === 304 && stored !== undefined) {
				await context.publish({ persist: { ...stored, checkedAt } });
				return;
			}
			if (response.status === 404 || response.status === 501) {
				await context.publish({ persist: { models: [], checkedAt, lastModified: 0 } });
				return;
			}
			if (!response.ok) {
				// The saved list and its validator stay; the next refresh tries again.
				await context.publish({ persist: { ...(stored ?? { models: [] }), checkedAt } });
				throw new Error(`Model list request failed for ${provider.id}: ${response.status}`);
			}
			const body = (await response.json()) as unknown;
			const models = Array.isArray(body)
				? body
				: typeof body === "object" && body !== null && Array.isArray((body as { models?: unknown }).models)
					? (body as { models: unknown[] }).models
					: typeof body === "object" && body !== null
						? Object.values(body)
						: [];
			const lastModified = Date.parse(response.headers.get("last-modified") ?? "");
			const entry: ModelsStoreEntry = {
				models: usable(provider, models),
				lastModified: Number.isNaN(lastModified) ? 0 : lastModified,
				checkedAt,
				...(response.headers.get("etag") === null ? {} : { etag: response.headers.get("etag")! }),
			};
			const published = newer(entry) ? entry.models : [];
			await context.publish({ persist: entry, update: () => (remote = [...published]) });
		},
	};
}
