// Keyed HTTP APIs behind tools. A tool calls `serviceFetch` with the service's
// key placeholder wherever the API wants the key; Swift's fetch bridge swaps in the Keychain key on the service's
// hosts only, and counts and caps its monthly requests. Here: spacing for per-second limits, one retry after a 429,
// and errors the model can act on.

import { keyPlaceholder } from "./models.ts";

export type Service = {
	readonly id: string;
	readonly name: string;
	/** Least time between two requests' starts. */
	readonly minIntervalMs?: number;
};

export const services = {
	deepseek: { id: "deepseek", name: "DeepSeek" },
	// Brave's free plan: 1 request per second (and 2,000 a month, capped in Swift).
	brave: { id: "brave", name: "Brave Search", minIntervalMs: 1100 },
	// The user's own node; its host is set from Swift, as `custom`'s is.
	proxmox: { id: "proxmox", name: "Proxmox VE" },
} satisfies Record<string, Service>;

/** The value to put where the service's key goes; also valid inside a URL query. */
export const servicePlaceholder = (service: Service) => keyPlaceholder(service.id);

/**
 * A service URL with query values from the model. Swift would put the key in place of any placeholder in the query, and
 * an API may echo the query back (Brave's `query.original`), so a value holding one is refused. `keyParam` adds the
 * service's key placeholder as that parameter, for APIs that take the key in the URL.
 */
export function serviceUrl(service: Service, base: string, params: Record<string, string>, keyParam?: string): string {
	for (const value of Object.values(params)) {
		if (value.toLowerCase().includes("pi-host-key:")) throw new ServiceError(`${service.name}: the request may not contain "pi-host-key:".`);
	}
	const query = new URLSearchParams(params);
	if (keyParam !== undefined) query.set(keyParam, servicePlaceholder(service));
	return `${base}?${query}`;
}

/** Longest `Retry-After` worth waiting for inside a tool call. */
const MAX_RETRY_WAIT_MS = 10_000;

const nextStart = new Map<string, number>();

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
	return new Promise((resolve, reject) => {
		if (signal?.aborted) return reject(signal.reason);
		if (ms <= 0) return resolve();
		const onAbort = () => {
			clearTimeout(timer);
			reject(signal!.reason);
		};
		const timer = setTimeout(() => {
			signal?.removeEventListener("abort", onAbort);
			resolve();
		}, ms);
		signal?.addEventListener("abort", onAbort, { once: true });
	});
}

/** Waits for the service's next free slot. JS is single-threaded, so taking a slot is atomic. */
async function slot(service: Service, signal?: AbortSignal): Promise<void> {
	const gap = service.minIntervalMs;
	if (gap === undefined) return;
	const now = Date.now();
	const at = Math.max(now, nextStart.get(service.id) ?? 0);
	nextStart.set(service.id, at + gap);
	await sleep(at - now, signal);
}

export class ServiceError extends Error {
	constructor(
		message: string,
		readonly status?: number,
		/** The API's own error text, if it sent one. */
		readonly detail?: string,
	) {
		super(message);
		this.name = "ServiceError";
	}
}

/** The API's own error text, from the shapes DeepSeek (OpenAI-style) and Brave use. */
function errorDetail(body: string): string {
	try {
		const parsed = JSON.parse(body) as { error?: { message?: string; detail?: string } | string; message?: string; detail?: string };
		const error = parsed.error;
		const text = typeof error === "string" ? error : (error?.message ?? error?.detail ?? parsed.message ?? parsed.detail);
		if (typeof text === "string" && text !== "") return text.slice(0, 300);
	} catch {}
	return body.trim().slice(0, 300);
}

function failure(service: Service, status: number, body: string): ServiceError {
	const detail = errorDetail(body);
	const why =
		status === 401 || status === 403
			? `the API key was refused. Check the ${service.name} key in Settings.`
			: status === 402
				? "the account is out of balance."
				: status === 429
					? "too many requests or the plan's quota is used up. Try again later."
					: status >= 500
						? "the service had an error. Try again later."
						: "the request was rejected.";
	return new ServiceError(`${service.name}: ${why}${detail ? ` (${status}: ${detail})` : ` (${status})`}`, status, detail || undefined);
}

/**
 * Sends one request to a service and returns the successful response. Throws a `ServiceError` with a message for
 * the model when the request fails, including Swift's refusals (no key, monthly quota used up).
 */
export async function serviceFetch(service: Service, url: string, init: RequestInit = {}, signal?: AbortSignal): Promise<Response> {
	for (let attempt = 0; ; attempt++) {
		await slot(service, signal);
		let response: Response;
		try {
			response = await fetch(url, { ...init, signal });
		} catch (error) {
			if (signal?.aborted) throw error;
			const message = error instanceof Error ? error.message.replace(/^fetch failed: /, "") : String(error);
			throw new ServiceError(`${service.name}: ${message}`);
		}
		if (response.ok) return response;
		const body = await response.text().catch(() => "");
		if (response.status === 429 && attempt === 0) {
			const retryAfter = Number(response.headers.get("retry-after"));
			const waitMs = Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : (service.minIntervalMs ?? 1000);
			if (waitMs <= MAX_RETRY_WAIT_MS) {
				await sleep(waitMs, signal);
				continue;
			}
		}
		throw failure(service, response.status, body);
	}
}
