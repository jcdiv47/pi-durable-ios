// Web globals a plain JSContext lacks. Imported first by every bundle entry.
// Natively backed: timers, console, performance, crypto, UTF-8. Pure JS: everything else.

import URLPolyfill from "core-js-pure/stable/url/index.js";
import URLSearchParamsPolyfill from "core-js-pure/stable/url-search-params/index.js";
import {
	ByteLengthQueuingStrategy,
	CountQueuingStrategy,
	ReadableStream,
	TransformStream,
	WritableStream,
} from "web-streams-polyfill";
import { fetchHandlers, installFetch } from "./fetch.ts";
import { type HostCallbacks, native } from "./native.ts";

const g = globalThis as Record<string, unknown>;

function define(name: string, value: unknown): void {
	if (g[name] === undefined) {
		Object.defineProperty(globalThis, name, { value, writable: true, configurable: true, enumerable: false });
	}
}

// ---- console -------------------------------------------------------------

function formatValue(value: unknown, depth = 0): string {
	if (typeof value === "string") return depth === 0 ? value : JSON.stringify(value);
	if (value instanceof Error) return `${value.name}: ${value.message}${value.stack ? `\n${value.stack}` : ""}`;
	if (typeof value === "object" && value !== null) {
		try {
			return JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? `${v}n` : v));
		} catch {
			return String(value);
		}
	}
	return String(value);
}

const log =
	(level: string) =>
	(...args: unknown[]) =>
		native.log(level, args.map((a) => formatValue(a)).join(" "));
g.console = {
	log: log("info"),
	info: log("info"),
	debug: log("debug"),
	trace: log("debug"),
	warn: log("warn"),
	error: log("error"),
	assert: (condition: unknown, ...args: unknown[]) => {
		if (!condition) log("error")("Assertion failed", ...args);
	},
	time: () => {},
	timeEnd: () => {},
	group: () => {},
	groupEnd: () => {},
	table: log("info"),
	dir: log("info"),
};

// ---- timers --------------------------------------------------------------

type TimerEntry = { callback: (...args: unknown[]) => void; args: unknown[]; interval?: number };
const timers = new Map<number, TimerEntry>();
let nextTimerId = 1;

/** Node-style handle so `timer.unref?.()` and `ref()` work; numeric coercion gives the id. */
class TimerHandle {
	constructor(readonly id: number) {}
	ref(): this {
		return this;
	}
	unref(): this {
		return this;
	}
	hasRef(): boolean {
		return true;
	}
	refresh(): this {
		return this;
	}
	[Symbol.toPrimitive](): number {
		return this.id;
	}
}

function startTimer(callback: unknown, ms: unknown, args: unknown[], repeat: boolean): TimerHandle {
	if (typeof callback !== "function") throw new TypeError("Timer callback must be a function");
	const id = nextTimerId++;
	const delay = Math.max(0, Number(ms) || 0);
	timers.set(id, { callback: callback as TimerEntry["callback"], args, interval: repeat ? delay : undefined });
	native.setTimer(id, delay);
	return new TimerHandle(id);
}

function stopTimer(handle: unknown): void {
	if (handle === undefined || handle === null) return;
	const id = Number(handle);
	if (timers.delete(id)) native.clearTimer(id);
}

g.setTimeout = (callback: unknown, ms?: unknown, ...args: unknown[]) => startTimer(callback, ms, args, false);
g.setInterval = (callback: unknown, ms?: unknown, ...args: unknown[]) => startTimer(callback, ms, args, true);
g.clearTimeout = stopTimer;
g.clearInterval = stopTimer;
define("queueMicrotask", (callback: () => void) => {
	Promise.resolve()
		.then(callback)
		.catch((error) => {
			console.error("Uncaught error in microtask", error);
		});
});

// ---- performance ---------------------------------------------------------

const timeOrigin = Date.now() - native.now();
define("performance", {
	now: () => native.now(),
	timeOrigin,
	mark: () => undefined,
	measure: () => undefined,
	getEntriesByName: () => [],
});

// ---- crypto --------------------------------------------------------------

function getRandomValues<T extends ArrayBufferView>(array: T): T {
	if (!ArrayBuffer.isView(array) || array instanceof Float32Array || array instanceof Float64Array) {
		throw new TypeError("getRandomValues expects an integer typed array");
	}
	if (array.byteLength > 65536) throw new RangeError("getRandomValues: quota exceeded");
	native.randomFill(new Uint8Array(array.buffer, array.byteOffset, array.byteLength));
	return array;
}

function randomUUID(): string {
	const b = getRandomValues(new Uint8Array(16));
	b[6] = (b[6]! & 0x0f) | 0x40;
	b[8] = (b[8]! & 0x3f) | 0x80;
	const hex = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
	return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

define("crypto", { getRandomValues, randomUUID });

// ---- DOMException, Event, EventTarget ------------------------------------

const DOM_EXCEPTION_CODES: Record<string, number> = {
	IndexSizeError: 1,
	NotFoundError: 8,
	NotSupportedError: 9,
	InvalidStateError: 11,
	SyntaxError: 12,
	InvalidAccessError: 15,
	TypeMismatchError: 17,
	NetworkError: 19,
	AbortError: 20,
	TimeoutError: 23,
	DataCloneError: 25,
};

class DOMExceptionPolyfill extends Error {
	readonly code: number;
	constructor(message = "", name = "Error") {
		super(message);
		Object.defineProperty(this, "name", { value: name, configurable: true, writable: true });
		this.code = DOM_EXCEPTION_CODES[name] ?? 0;
	}
}
define("DOMException", DOMExceptionPolyfill);

type Listener = ((event: EventPolyfill) => void) | { handleEvent(event: EventPolyfill): void };

class EventPolyfill {
	readonly type: string;
	readonly bubbles: boolean;
	readonly cancelable: boolean;
	readonly timeStamp = Date.now();
	defaultPrevented = false;
	target: EventTargetPolyfill | null = null;
	currentTarget: EventTargetPolyfill | null = null;
	#stopped = false;
	constructor(type: string, init: { bubbles?: boolean; cancelable?: boolean } = {}) {
		this.type = String(type);
		this.bubbles = !!init.bubbles;
		this.cancelable = !!init.cancelable;
	}
	preventDefault(): void {
		if (this.cancelable) this.defaultPrevented = true;
	}
	stopImmediatePropagation(): void {
		this.#stopped = true;
	}
	stopPropagation(): void {}
	get immediateStopped(): boolean {
		return this.#stopped;
	}
}

class CustomEventPolyfill<T = unknown> extends EventPolyfill {
	readonly detail: T | null;
	constructor(type: string, init: { detail?: T; bubbles?: boolean; cancelable?: boolean } = {}) {
		super(type, init);
		this.detail = init.detail ?? null;
	}
}

type ListenerEntry = { listener: Listener; once: boolean; signal?: AbortSignalPolyfill };

class EventTargetPolyfill {
	#listeners = new Map<string, ListenerEntry[]>();

	addEventListener(
		type: string,
		listener: Listener | null,
		options?: boolean | { once?: boolean; signal?: AbortSignalPolyfill },
	): void {
		if (listener === null || listener === undefined) return;
		const opts = typeof options === "object" && options !== null ? options : {};
		if (opts.signal?.aborted) return;
		const list = this.#listeners.get(type) ?? [];
		if (list.some((e) => e.listener === listener)) return;
		const entry: ListenerEntry = { listener, once: !!opts.once, signal: opts.signal };
		list.push(entry);
		this.#listeners.set(type, list);
		opts.signal?.addEventListener("abort", () => this.removeEventListener(type, listener), { once: true });
	}

	removeEventListener(type: string, listener: Listener | null): void {
		const list = this.#listeners.get(type);
		if (list === undefined) return;
		const index = list.findIndex((e) => e.listener === listener);
		if (index >= 0) list.splice(index, 1);
	}

	dispatchEvent(event: EventPolyfill): boolean {
		event.target = this;
		event.currentTarget = this;
		const handlerProp = (this as Record<string, unknown>)[`on${event.type}`];
		const list = [...(this.#listeners.get(event.type) ?? [])];
		const run = (listener: Listener) => {
			try {
				if (typeof listener === "function") listener.call(this, event);
				else listener.handleEvent(event);
			} catch (error) {
				console.error(`Uncaught error in "${event.type}" listener`, error);
			}
		};
		if (typeof handlerProp === "function") run(handlerProp as Listener);
		for (const entry of list) {
			if (event.immediateStopped) break;
			if (entry.once) this.removeEventListener(event.type, entry.listener);
			run(entry.listener);
		}
		return !event.defaultPrevented;
	}
}

define("Event", EventPolyfill);
define("CustomEvent", CustomEventPolyfill);
define("EventTarget", EventTargetPolyfill);

// ---- AbortController / AbortSignal ---------------------------------------

class AbortSignalPolyfill extends EventTargetPolyfill {
	aborted = false;
	reason: unknown = undefined;
	onabort: ((event: EventPolyfill) => void) | null = null;

	throwIfAborted(): void {
		if (this.aborted) throw this.reason;
	}

	/** @internal */
	_abort(reason: unknown): void {
		if (this.aborted) return;
		this.aborted = true;
		this.reason = reason === undefined ? new DOMExceptionPolyfill("This operation was aborted", "AbortError") : reason;
		this.dispatchEvent(new EventPolyfill("abort"));
	}

	static abort(reason?: unknown): AbortSignalPolyfill {
		const signal = new AbortSignalPolyfill();
		signal._abort(reason);
		return signal;
	}

	static timeout(ms: number): AbortSignalPolyfill {
		const signal = new AbortSignalPolyfill();
		setTimeout(() => signal._abort(new DOMExceptionPolyfill("The operation timed out.", "TimeoutError")), ms);
		return signal;
	}

	static any(signals: Iterable<AbortSignalPolyfill>): AbortSignalPolyfill {
		const result = new AbortSignalPolyfill();
		const list = [...signals];
		const done = list.find((s) => s.aborted);
		if (done !== undefined) {
			result._abort(done.reason);
			return result;
		}
		// Weakly held so a long-lived parent signal does not keep every derived signal alive.
		const ref = new WeakRef(result);
		const cleanups: (() => void)[] = [];
		for (const signal of list) {
			const onAbort = () => {
				ref.deref()?._abort(signal.reason);
				for (const cleanup of cleanups) cleanup();
			};
			signal.addEventListener("abort", onAbort, { once: true });
			cleanups.push(() => signal.removeEventListener("abort", onAbort));
		}
		return result;
	}
}

class AbortControllerPolyfill {
	readonly signal = new AbortSignalPolyfill();
	abort(reason?: unknown): void {
		this.signal._abort(reason);
	}
}

define("AbortSignal", AbortSignalPolyfill);
define("AbortController", AbortControllerPolyfill);

// ---- TextEncoder / TextDecoder (UTF-8 only) ------------------------------

class TextEncoderPolyfill {
	readonly encoding = "utf-8";
	encode(input = ""): Uint8Array {
		return native.utf8Encode(String(input));
	}
	encodeInto(input: string, destination: Uint8Array): { read: number; written: number } {
		// Encode code point by code point so `read` counts UTF-16 units of what fit.
		let read = 0;
		let written = 0;
		for (const ch of String(input)) {
			const bytes = native.utf8Encode(ch);
			if (written + bytes.length > destination.length) break;
			destination.set(bytes, written);
			written += bytes.length;
			read += ch.length;
		}
		return { read, written };
	}
}

function toBytes(input: unknown): Uint8Array {
	if (input === undefined) return new Uint8Array(0);
	if (input instanceof Uint8Array) return input;
	if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
	if (input instanceof ArrayBuffer || (typeof SharedArrayBuffer !== "undefined" && input instanceof SharedArrayBuffer)) {
		return new Uint8Array(input);
	}
	throw new TypeError("TextDecoder.decode expects an ArrayBuffer or ArrayBufferView");
}

/** Length of the longest prefix of `bytes` that does not end inside a UTF-8 sequence. */
function completePrefixLength(bytes: Uint8Array): number {
	const n = bytes.length;
	for (let back = 1; back <= Math.min(3, n); back++) {
		const b = bytes[n - back]!;
		if ((b & 0xc0) === 0x80) continue; // continuation byte, keep looking for the lead
		const need = b >= 0xf0 ? 4 : b >= 0xe0 ? 3 : b >= 0xc0 ? 2 : 1;
		return need > back ? n - back : n;
	}
	return n;
}

class TextDecoderPolyfill {
	readonly encoding = "utf-8";
	readonly fatal: boolean;
	readonly ignoreBOM: boolean;
	#pending: Uint8Array | null = null;
	#bomSeen = false;

	constructor(label = "utf-8", options: { fatal?: boolean; ignoreBOM?: boolean } = {}) {
		const normalized = String(label).trim().toLowerCase();
		if (normalized !== "utf-8" && normalized !== "utf8" && normalized !== "unicode-1-1-utf-8") {
			throw new RangeError(`TextDecoder: unsupported encoding "${label}"`);
		}
		this.fatal = !!options.fatal;
		this.ignoreBOM = !!options.ignoreBOM;
	}

	decode(input?: unknown, options: { stream?: boolean } = {}): string {
		let bytes = toBytes(input);
		if (this.#pending !== null) {
			const joined = new Uint8Array(this.#pending.length + bytes.length);
			joined.set(this.#pending, 0);
			joined.set(bytes, this.#pending.length);
			bytes = joined;
			this.#pending = null;
		}
		if (options.stream) {
			const cut = completePrefixLength(bytes);
			if (cut < bytes.length) {
				this.#pending = bytes.slice(cut);
				bytes = bytes.subarray(0, cut);
			}
		}
		const decoded = bytes.length === 0 ? "" : native.utf8Decode(bytes, this.fatal);
		if (decoded === null) throw new TypeError("The encoded data was not valid UTF-8");
		let text = decoded;
		if (!this.#bomSeen && text.length > 0) {
			this.#bomSeen = true;
			if (!this.ignoreBOM && text.charCodeAt(0) === 0xfeff) text = text.slice(1);
		}
		if (!options.stream) this.#bomSeen = false;
		return text;
	}
}

define("TextEncoder", TextEncoderPolyfill);
define("TextDecoder", TextDecoderPolyfill);

// ---- streams -------------------------------------------------------------

define("ReadableStream", ReadableStream);
define("WritableStream", WritableStream);
define("TransformStream", TransformStream);
define("ByteLengthQueuingStrategy", ByteLengthQueuingStrategy);
define("CountQueuingStrategy", CountQueuingStrategy);

class TextDecoderStreamPolyfill extends TransformStream<Uint8Array, string> {
	constructor(label = "utf-8", options: { fatal?: boolean; ignoreBOM?: boolean } = {}) {
		const decoder = new TextDecoderPolyfill(label, options);
		super({
			transform(chunk, controller) {
				const text = decoder.decode(chunk, { stream: true });
				if (text) controller.enqueue(text);
			},
			flush(controller) {
				const text = decoder.decode();
				if (text) controller.enqueue(text);
			},
		});
	}
}

class TextEncoderStreamPolyfill extends TransformStream<string, Uint8Array> {
	constructor() {
		const encoder = new TextEncoderPolyfill();
		super({
			transform(chunk, controller) {
				controller.enqueue(encoder.encode(chunk));
			},
		});
	}
}

define("TextDecoderStream", TextDecoderStreamPolyfill);
define("TextEncoderStream", TextEncoderStreamPolyfill);

// ---- URL -----------------------------------------------------------------

define("URL", URLPolyfill);
define("URLSearchParams", URLSearchParamsPolyfill);

// ---- base64 --------------------------------------------------------------

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const B64_LOOKUP = new Map<string, number>([...B64].map((c, i) => [c, i]));

define("btoa", (input: string) => {
	const s = String(input);
	let out = "";
	for (let i = 0; i < s.length; i += 3) {
		const a = s.charCodeAt(i);
		const b = s.charCodeAt(i + 1);
		const c = s.charCodeAt(i + 2);
		if (a > 255 || b > 255 || c > 255) throw new DOMExceptionPolyfill("Invalid character", "InvalidCharacterError");
		const n = (a << 16) | ((b || 0) << 8) | (c || 0);
		out += B64[(n >> 18) & 63]! + B64[(n >> 12) & 63]!;
		out += i + 1 < s.length ? B64[(n >> 6) & 63]! : "=";
		out += i + 2 < s.length ? B64[n & 63]! : "=";
	}
	return out;
});

define("atob", (input: string) => {
	const s = String(input).replace(/[\t\n\f\r ]/g, "").replace(/=+$/, "");
	if (s.length % 4 === 1) throw new DOMExceptionPolyfill("Invalid base64", "InvalidCharacterError");
	let out = "";
	let buffer = 0;
	let bits = 0;
	for (const c of s) {
		const v = B64_LOOKUP.get(c);
		if (v === undefined) throw new DOMExceptionPolyfill("Invalid base64", "InvalidCharacterError");
		buffer = (buffer << 6) | v;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			out += String.fromCharCode((buffer >> bits) & 0xff);
		}
	}
	return out;
});

// ---- structuredClone -----------------------------------------------------

function cloneValue(value: unknown, seen: Map<object, unknown>): unknown {
	if (typeof value !== "object" || value === null) {
		if (typeof value === "function" || typeof value === "symbol") {
			throw new DOMExceptionPolyfill(`${String(value)} could not be cloned.`, "DataCloneError");
		}
		return value;
	}
	const existing = seen.get(value);
	if (existing !== undefined) return existing;
	if (value instanceof Date) return new Date(value.getTime());
	if (value instanceof RegExp) return new RegExp(value.source, value.flags);
	if (value instanceof ArrayBuffer) {
		const copy = value.slice(0);
		seen.set(value, copy);
		return copy;
	}
	if (ArrayBuffer.isView(value)) {
		const ctor = value.constructor as new (buffer: ArrayBuffer, offset: number, length: number) => ArrayBufferView;
		const buffer = cloneValue(value.buffer, seen) as ArrayBuffer;
		const length = value instanceof DataView ? value.byteLength : (value as unknown as { length: number }).length;
		const copy = new ctor(buffer, value.byteOffset, length);
		seen.set(value, copy);
		return copy;
	}
	if (value instanceof Map) {
		const copy = new Map();
		seen.set(value, copy);
		for (const [k, v] of value) copy.set(cloneValue(k, seen), cloneValue(v, seen));
		return copy;
	}
	if (value instanceof Set) {
		const copy = new Set();
		seen.set(value, copy);
		for (const v of value) copy.add(cloneValue(v, seen));
		return copy;
	}
	if (value instanceof Error) {
		const copy = new (value.constructor as ErrorConstructor)(value.message);
		seen.set(value, copy);
		if (value.stack !== undefined) copy.stack = value.stack;
		if ("cause" in value) copy.cause = cloneValue(value.cause, seen);
		return copy;
	}
	if (value instanceof Boolean || value instanceof Number || value instanceof String) {
		return Object(value.valueOf());
	}
	if (Array.isArray(value)) {
		const copy: unknown[] = new Array(value.length);
		seen.set(value, copy);
		for (let i = 0; i < value.length; i++) if (i in value) copy[i] = cloneValue(value[i], seen);
		return copy;
	}
	const proto = Object.getPrototypeOf(value);
	if (proto !== Object.prototype && proto !== null) {
		// Class instances clone as plain objects of their own enumerable properties, as in browsers.
		if (typeof (value as { then?: unknown }).then === "function" || value instanceof Promise || value instanceof WeakMap) {
			throw new DOMExceptionPolyfill("Value could not be cloned.", "DataCloneError");
		}
	}
	const copy: Record<string, unknown> = {};
	seen.set(value, copy);
	for (const key of Object.keys(value)) copy[key] = cloneValue((value as Record<string, unknown>)[key], seen);
	return copy;
}

define("structuredClone", (value: unknown) => cloneValue(value, new Map()));

// ---- fetch, Headers, Request, Response, Blob, File, FormData -------------

installFetch(define);

// ---- host callbacks ------------------------------------------------------

const host: HostCallbacks = {
	fireTimer(id) {
		const entry = timers.get(id);
		if (entry === undefined) return;
		if (entry.interval === undefined) timers.delete(id);
		else native.setTimer(id, entry.interval);
		try {
			entry.callback(...entry.args);
		} catch (error) {
			console.error("Uncaught error in timer", error);
		}
	},
	fetchEvent(id, type, payload) {
		fetchHandlers.get(id)?.(type, payload);
	},
};
g.__piHost = host;
