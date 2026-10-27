// Async calls from JS into Swift handlers (Apple tools, app settings). Swift answers on the JS queue
// through `__piHost.hostResult`, so a call never blocks the queue while EventKit or HealthKit works.

import { native } from "./native.ts";

const pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
let nextId = 1;

/** Calls Swift handler `name` with JSON `args`; resolves with its JSON result. Abort only stops the wait. */
export function hostCall<T = unknown>(name: string, args: unknown, signal?: AbortSignal): Promise<T> {
	return new Promise<T>((resolve, reject) => {
		if (signal?.aborted) return reject(signal.reason);
		const id = nextId++;
		const onAbort = () => {
			pending.delete(id);
			reject(signal!.reason);
		};
		pending.set(id, {
			resolve: (value) => {
				signal?.removeEventListener("abort", onAbort);
				resolve(value as T);
			},
			reject: (error) => {
				signal?.removeEventListener("abort", onAbort);
				reject(error);
			},
		});
		signal?.addEventListener("abort", onAbort, { once: true });
		native.hostCall(id, name, JSON.stringify(args ?? null));
	});
}

export function settleHostCall(id: number, ok: boolean, json: string): void {
	const call = pending.get(id);
	if (call === undefined) return;
	pending.delete(id);
	if (!ok) return call.reject(new Error(json));
	try {
		call.resolve(JSON.parse(json));
	} catch (error) {
		call.reject(error instanceof Error ? error : new Error(String(error)));
	}
}
