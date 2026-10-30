// Web tools (docs/adr/0004-http-api-services.md): `web_search` through the provider chosen in Settings (DeepSeek
// Search or Brave Web Search) and `web_fetch`, which reads a page as Markdown through DeepSeek Fetch. Both are reads, so
// replay-safe; a rerun after a crash costs one more request.
//
// `web_fetch` is how a page could send data out (`evil.example/?d=…`). It asks for approval by default, except for
// URLs that came from a search result or a user message in the conversation (`fetchTrusted`, used by the approval gate).

import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, type EntryRecord, section } from "@earendil-works/pi-durable";
import { textOf } from "./display.ts";
import { OriginInput } from "./schedule.ts";
import { type Service, ServiceError, serviceFetch, servicePlaceholder, services, serviceUrl } from "./services.ts";

export type SearchProviderId = "off" | "deepseek" | "brave" | "scripted";

/** Set from Settings through `PiRuntime.setSearchProvider` and `configureProviders`. */
export const webSettings = {
	provider: "off" as SearchProviderId,
	/** Whether Swift holds a key for the service. */
	keyed: (_service: string) => false as boolean,
};

type Freshness = "day" | "week" | "month" | "year";
type SearchQuery = { query: string; count: number; freshness?: Freshness };
export type SearchResult = { title: string; url: string; snippet: string; date?: string; site?: string };
type Page = { title: string; content: string };

type SearchProvider = {
	readonly service: Service;
	search(query: SearchQuery, signal?: AbortSignal): Promise<SearchResult[]>;
};

/** Search output the model sees, and the card draws. */
const MAX_SEARCH_CHARS = 8_000;
const MAX_SNIPPET_CHARS = 1_000;
const MAX_PAGE_CHARS = 24_000;

function stripTags(text: string | undefined): string {
	return (text ?? "")
		.replace(/<[^>]+>/g, "")
		.replace(/&quot;/g, '"')
		.replace(/&#39;/g, "'")
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&amp;/g, "&")
		.trim();
}

const freshnessDays: Record<Freshness, number> = { day: 1, week: 7, month: 31, year: 365 };

const deepseekSearch: SearchProvider = {
	service: services.deepseek,
	async search({ query, count, freshness }, signal) {
		// DeepSeek has no freshness parameter; its query takes `after:YYYY-MM-DD`. The query is at most 128 characters.
		const after = freshness && ` after:${new Date(Date.now() - freshnessDays[freshness] * 86_400_000).toISOString().slice(0, 10)}`;
		const q = query.slice(0, 128 - (after?.length ?? 0)) + (after ?? "");
		const response = await serviceFetch(
			services.deepseek,
			"https://api.deepseek.com/v1/tools/search",
			{
				method: "POST",
				headers: { authorization: `Bearer ${servicePlaceholder(services.deepseek)}`, "content-type": "application/json" },
				body: JSON.stringify({ query: q, count }),
			},
			signal,
		);
		type Result = { title?: string; url?: string; snippet?: string; summary?: string; site_name?: string | null; date?: string | null };
		const body = (await response.json()) as { results?: Result[] };
		return (body.results ?? []).map((r) => ({
			title: r.title ?? "",
			url: r.url ?? "",
			// `summary` is written for models; `snippet` is the short one for a results page.
			snippet: r.summary || r.snippet || "",
			date: r.date ?? undefined,
			site: r.site_name ?? undefined,
		}));
	},
};

const braveFreshness: Record<Freshness, string> = { day: "pd", week: "pw", month: "pm", year: "py" };

const braveSearch: SearchProvider = {
	service: services.brave,
	async search({ query, count, freshness }, signal) {
		const params: Record<string, string> = {
			q: query.slice(0, 400),
			count: String(Math.min(count, 20)),
			extra_snippets: "true",
			text_decorations: "false",
		};
		if (freshness) params.freshness = braveFreshness[freshness];
		const response = await serviceFetch(
			services.brave,
			serviceUrl(services.brave, "https://api.search.brave.com/res/v1/web/search", params),
			{ headers: { accept: "application/json", "x-subscription-token": servicePlaceholder(services.brave) } },
			signal,
		);
		type Result = {
			title?: string;
			url?: string;
			description?: string;
			extra_snippets?: string[];
			page_age?: string;
			age?: string;
			profile?: { name?: string };
			meta_url?: { hostname?: string };
		};
		const body = (await response.json()) as { web?: { results?: Result[] } };
		return (body.web?.results ?? []).map((r) => ({
			title: stripTags(r.title),
			url: r.url ?? "",
			snippet: [r.description, ...(r.extra_snippets ?? [])].map(stripTags).filter(Boolean).join(" … "),
			date: r.page_age ?? r.age,
			site: r.profile?.name ?? r.meta_url?.hostname,
		}));
	},
};

/** Offline answers for tests and the scripted model. */
const scriptedService: Service = { id: "scripted", name: "Offline search" };

const scriptedSearch: SearchProvider = {
	service: scriptedService,
	async search({ query, count }) {
		const results: SearchResult[] = [
			{
				title: "Pi Durable",
				url: "https://earendil.com/posts/pi-durable/",
				snippet: `A durable agent harness: every model request, tool call and compaction survives a restart. (Query: ${query})`,
				date: "2026-06-01T00:00:00+00:00",
				site: "Earendil",
			},
			{
				title: "Pi 1.0",
				url: "https://earendil.com/posts/pi-1-0/",
				snippet: "The first stable release of Pi. More at https://example.com/from-a-snippet",
				site: "Earendil",
			},
		];
		return results.slice(0, count);
	},
};

const searchProviders: Record<Exclude<SearchProviderId, "off">, SearchProvider> = {
	deepseek: deepseekSearch,
	brave: braveSearch,
	scripted: scriptedSearch,
};

/** The provider to search with, or why there is none. */
function searchProvider(): SearchProvider | string {
	const id = webSettings.provider;
	if (id === "off") return "Web search is off. The user can turn it on in Settings › Web search.";
	const provider = searchProviders[id];
	if (id !== "scripted" && !webSettings.keyed(provider.service.id)) {
		return `Web search uses ${provider.service.name}, which has no API key. The user can add one in Settings.`;
	}
	return provider;
}

/** How pages are read, or why they can't be: DeepSeek Fetch needs a DeepSeek key. */
function pageReader(): ((url: string, signal?: AbortSignal) => Promise<Page>) | string {
	if (webSettings.provider === "scripted") {
		return async (url) => ({ title: "Offline page", content: `# Offline page\n\nThe scripted reader's text for ${url}.` });
	}
	if (!webSettings.keyed(services.deepseek.id)) return "Reading pages uses DeepSeek's Fetch API. The user can add a DeepSeek key in Settings.";
	return async (url, signal) => {
		const response = await serviceFetch(
			services.deepseek,
			"https://api.deepseek.com/v1/tools/fetch",
			{
				method: "POST",
				headers: { authorization: `Bearer ${servicePlaceholder(services.deepseek)}`, "content-type": "application/json" },
				body: JSON.stringify({ url }),
			},
			signal,
		);
		const body = (await response.json()) as { title?: string; content?: string };
		return { title: body.title ?? "", content: body.content ?? "" };
	};
}

/** Keeps whole results, dropping from the end until the output fits. */
function fit(results: SearchResult[]): SearchResult[] {
	const kept = results
		.filter((r) => r.url !== "")
		.map((r) => (r.snippet.length > MAX_SNIPPET_CHARS ? { ...r, snippet: `${r.snippet.slice(0, MAX_SNIPPET_CHARS)}…` } : r));
	while (kept.length > 1 && JSON.stringify(kept).length > MAX_SEARCH_CHARS) kept.pop();
	return kept;
}

function failed(error: unknown): never {
	throw error instanceof ServiceError ? new Error(error.message) : error;
}

const freshnessType = Type.Union(
	(Object.keys(freshnessDays) as Freshness[]).map((f) => Type.Literal(f)),
	{ description: "Only pages from the past day, week, month or year" },
);

const webSearch = defineTool({
	name: "web_search",
	description:
		"Search the web. Returns results with title, url, snippet and, when known, date and site. " +
		'The query may use site:example.com, "exact phrase" and -word. Cite the URLs you use.',
	parameters: Type.Object({
		query: Type.String({ description: "What to search for" }),
		count: Type.Optional(Type.Number({ description: "How many results, 1 to 20 (default 8)" })),
		freshness: Type.Optional(freshnessType),
	}),
	replay: "safe",
	execute: async (args, _api, context) => {
		const provider = searchProvider();
		if (typeof provider === "string") throw new Error(provider);
		const query = args.query.trim();
		if (query === "") throw new Error("The query is empty.");
		const count = Math.max(1, Math.min(20, Math.round(args.count ?? 8)));
		const results = await provider.search({ query, count, freshness: args.freshness }, context.abortSignal).catch(failed);
		const output = { provider: provider.service.name, query, results: fit(results) };
		return { output: [{ type: "text" as const, text: JSON.stringify(output, null, 1) }] };
	},
});

const webFetch = defineTool({
	name: "web_fetch",
	description:
		"Read a web page as Markdown. URLs from web_search results or from the user's messages run at once; " +
		"any other URL asks the user first.",
	parameters: Type.Object({
		url: Type.String({ description: "An http or https URL" }),
	}),
	replay: "safe",
	execute: async (args, _api, context) => {
		const url = normalizeUrl(args.url.trim());
		if (url === undefined || !/^https?:$/.test(new URL(url).protocol) || new URL(url).username !== "") {
			throw new Error("The url must be a plain http or https URL.");
		}
		const reader = pageReader();
		if (typeof reader === "string") throw new Error(reader);
		const page = await reader(url, context.abortSignal).catch(failed);
		const cut = page.content.length > MAX_PAGE_CHARS;
		const text = [
			page.title ? `Title: ${page.title}` : undefined,
			`URL: ${url}`,
			"",
			cut ? page.content.slice(0, MAX_PAGE_CHARS) : page.content,
			cut ? `\n[Cut at ${MAX_PAGE_CHARS.toLocaleString("en-US")} of ${page.content.length.toLocaleString("en-US")} characters]` : undefined,
		]
			.filter((line) => line !== undefined)
			.join("\n");
		return { output: [{ type: "text" as const, text }] };
	},
});

/** Present only when search works, so a setup without it costs no prompt. */
const webSection = section("web", () => {
	if (typeof searchProvider() === "string") return undefined;
	const reading =
		typeof pageReader() === "string"
			? "web_fetch is not set up, so work from the search snippets."
			: "Read a result with web_fetch when the snippets are not enough.";
	return [
		"Search the web with web_search when the answer depends on recent events or on facts you are not sure of.",
		reading,
		"Name your sources as Markdown links.",
	].join(" ");
});

export const WebTools = defineExtension({
	name: "web",
	sections: [webSection],
	tools: [webSearch, webFetch],
});

/** Tool names with what they do, for the approval settings screen. */
export const webToolInfo = WebTools.tools!.map((tool) => ({ name: tool.name, description: tool.description }));

// ---- trusted URLs ----------------------------------------------------------

const URL_PATTERN = /https?:\/\/[^\s<>"'`)\]}]+/g;

export function normalizeUrl(url: string): string | undefined {
	try {
		const parsed = new URL(url);
		parsed.hash = "";
		return parsed.href;
	} catch {
		return undefined;
	}
}

function urlsIn(text: string): string[] {
	return [...text.matchAll(URL_PATTERN)].flatMap((match) => normalizeUrl(match[0].replace(/[.,;:!?]+$/, "")) ?? []);
}

/** The results' own links in `web_search` output; a URL in the query or a snippet is not one. */
function resultUrls(text: string): string[] {
	try {
		const results = (JSON.parse(text) as { results?: { url?: unknown }[] }).results ?? [];
		return results.flatMap((result) => (typeof result.url === "string" ? (normalizeUrl(result.url) ?? []) : []));
	} catch {
		return [];
	}
}

/** URLs a conversation's user messages and search results hold: what `web_fetch` may read without asking. */
export function seenUrls(entries: readonly EntryRecord[]): Set<string> {
	const urls = new Set<string>();
	for (const entry of entries) {
		const message = entry.model?.[0] as { content?: unknown; toolName?: string; isError?: boolean } | undefined;
		if (entry.kind === "pi.user" || entry.kind === OriginInput) for (const url of urlsIn(textOf(message?.content))) urls.add(url);
		if (entry.kind === "pi.tool-result" && message?.toolName === "web_search" && message.isError !== true) {
			for (const url of resultUrls(textOf(message.content))) urls.add(url);
		}
	}
	return urls;
}

/** Whether a `web_fetch` call's URL appeared in the conversation. */
export function fetchTrusted(args: unknown, entries: readonly EntryRecord[]): boolean {
	const url = typeof (args as { url?: unknown })?.url === "string" ? normalizeUrl((args as { url: string }).url.trim()) : undefined;
	return url !== undefined && seenUrls(entries).has(url);
}
