// Model requests while the phone is offline. A request that fails because there is no network (a subway, a plane, a
// scheduled run in a dead spot) would count as a failed attempt under Pi's retry policy, and once the attempts are used
// up the run ends with an error. Instead, the request waits for the network and is sent again; the failure is never
// committed, so the attempt is not charged. After Batty's network-recovery.ts (github.com/jeffton/batty, MIT).
//
// Offline is no network path (NWPathMonitor), or a path on which nothing answers: a VPN tunnel (sing-box, Tailscale)
// keeps the path satisfied in Airplane Mode, and connections then fail inside it. So when the path looks online, the
// model's host and Apple's connectivity check are asked; any HTTP answer means the network works and the failure was
// something else, which goes to Pi's retry. The wait ends when one of them answers.
//
// Only a request that failed before showing anything waits: one cut off mid-answer has streamed text the transcript
// already shows, so it goes to Pi's retry as before (and its next attempt, sent while offline, waits here).
// iOS suspends the process while it waits; a process killed while waiting comes back as an interrupted attempt, which
// Pi charges and retries, and that retry waits here again.

import type { AssistantMessage, AssistantMessageEvent } from "@earendil-works/pi-ai";
import type { Models } from "@earendil-works/pi-ai/models";
import { AssistantMessageEventStream } from "@earendil-works/pi-ai/utils/event-stream";

type StreamSimple = Models["streamSimple"];

/** Errors a request gets when it never reached the server: our fetch's `fetch failed: …`, the SDKs' wording. */
const transportPattern =
	/fetch failed|connection error|network (?:error|connection)|internet connection|offline|could not connect|timed out|socket hang up|terminated|secure connection|tls error/i;

export function isTransportFailure(message: AssistantMessage): boolean {
	return message.stopReason === "error" && transportPattern.test(message.errorMessage ?? "");
}

/** Apple's connectivity check, reachable in every region the app is used in. */
export const probeUrl = "https://www.apple.com/library/test/success.html";

export type NetworkOptions = {
	/** Whether the device has a network path now (`NetworkPath` in PiRuntime). */
	online: () => boolean;
	/** How often to look again while offline. */
	pollMs?: number;
	/** How long a probe may take before its host counts as unreachable. */
	probeTimeoutMs?: number;
	/** Called with the number of requests waiting, whenever it changes. */
	onWaiting?: (waiting: number) => void;
};

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
	return new Promise((resolve, reject) => {
		if (signal?.aborted) return reject(signal.reason);
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

/** Whether `url` gives any HTTP answer within `timeoutMs`. */
async function answers(url: string, timeoutMs: number, signal?: AbortSignal): Promise<boolean> {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(new Error("probe timed out")), timeoutMs);
	const onAbort = () => controller.abort(signal!.reason);
	signal?.addEventListener("abort", onAbort, { once: true });
	try {
		const response = await fetch(url, { method: "HEAD", signal: controller.signal });
		await response.body?.cancel();
		return true;
	} catch {
		return false;
	} finally {
		clearTimeout(timer);
		signal?.removeEventListener("abort", onAbort);
	}
}

/** `streamSimple` whose requests wait while the device is offline instead of failing. */
export function waitWhileOffline(streamSimple: StreamSimple, options: NetworkOptions): StreamSimple {
	const { online, pollMs = 2000, probeTimeoutMs = 5000, onWaiting } = options;
	let waiting = 0;
	/** The model's host or Apple's answers: true as soon as one does. */
	const reachable = (baseUrl: string, signal?: AbortSignal) =>
		new Promise<boolean>((resolve) => {
			let origin: string | undefined;
			try {
				origin = new URL(baseUrl).origin;
			} catch {}
			const urls = origin === undefined ? [probeUrl] : [origin, probeUrl];
			let left = urls.length;
			for (const url of urls) {
				void answers(url, probeTimeoutMs, signal).then((ok) => {
					if (ok) resolve(true);
					else if (--left === 0) resolve(false);
				});
			}
		});
	const offline = async (baseUrl: string, signal?: AbortSignal) => {
		const result = !online() || !(await reachable(baseUrl, signal));
		signal?.throwIfAborted();
		return result;
	};

	return (model, context, requestOptions) => {
		const signal = requestOptions?.signal;
		const output = new AssistantMessageEventStream();
		let last: AssistantMessage | undefined;
		void (async () => {
			for (;;) {
				const source = streamSimple(model, context, requestOptions);
				// Events before the first content are held: if the request fails before any, it can be sent again unseen.
				const held: AssistantMessageEvent[] = [];
				let shown = false;
				let terminal: AssistantMessageEvent | undefined;
				for await (const event of source) {
					if (event.type === "done" || event.type === "error") {
						terminal = event;
						break;
					}
					if (!shown && event.partial.content.length === 0) {
						held.push(event);
						continue;
					}
					if (!shown) for (const early of held.splice(0)) output.push(early);
					shown = true;
					output.push(event);
				}
				last = await source.result();
				if (shown || !isTransportFailure(last) || !(await offline(model.baseUrl, signal))) {
					for (const early of held) output.push(early);
					if (terminal !== undefined) output.push(terminal);
					else output.end(last);
					return;
				}
				console.info(`Offline: ${model.provider}/${model.id} waits for the network (${last.errorMessage ?? "no network"})`);
				onWaiting?.(++waiting);
				try {
					do await sleep(pollMs, signal);
					while (await offline(model.baseUrl, signal));
				} finally {
					onWaiting?.(--waiting);
				}
				signal?.throwIfAborted();
				console.info(`Online: ${model.provider}/${model.id} sends its request again`);
			}
		})().catch((error: unknown) => {
			// Stopped while waiting: Pi's abort handles the run; the stream only has to end.
			const message: AssistantMessage = {
				...(last ?? {
					role: "assistant",
					content: [],
					api: model.api,
					provider: model.provider,
					model: model.id,
					usage: {
						input: 0,
						output: 0,
						cacheRead: 0,
						cacheWrite: 0,
						totalTokens: 0,
						cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
					},
					timestamp: Date.now(),
				}),
				stopReason: signal?.aborted ? "aborted" : "error",
				errorMessage: error instanceof Error ? error.message : String(error),
			};
			output.push({ type: "error", reason: message.stopReason as "error" | "aborted", error: message });
		});
		return output;
	};
}
