// Bindings the Swift host (PiRuntime) installs on `globalThis.__native` before any bundle runs.
// Swift only stores integer handles; it calls back into JS through `globalThis.__piHost`.

export type NativeSqliteValue = null | number | bigint | string | Uint8Array;

export interface NativeFetchRequest {
	readonly url: string;
	readonly method: string;
	readonly headers: [string, string][];
	readonly body: Uint8Array | null;
}

export interface NativeBindings {
	log(level: string, message: string): void;
	/** Schedules `__piHost.fireTimer(id)` after `ms` on the JS queue. */
	setTimer(id: number, ms: number): void;
	clearTimer(id: number): void;
	/** Monotonic milliseconds since the runtime started. */
	now(): number;
	/** Fills the typed array with cryptographically secure random bytes. */
	randomFill(bytes: Uint8Array): void;
	utf8Encode(text: string): Uint8Array;
	/** Decodes UTF-8. Invalid sequences become U+FFFD, or return null when `fatal`. */
	utf8Decode(bytes: Uint8Array, fatal: boolean): string | null;
	/** Starts a request; events arrive through `__piHost.fetchEvent(id, ...)`. */
	fetchStart(id: number, request: NativeFetchRequest): void;
	fetchCancel(id: number): void;
	sqliteOpen(path: string): number;
	sqliteExec(handle: number, sql: string): void;
	/** Resolves with the rows the statement changed. */
	sqliteRun(handle: number, sql: string, params: NativeSqliteValue[]): number;
	sqliteGet(handle: number, sql: string, params: NativeSqliteValue[]): Record<string, NativeSqliteValue> | undefined;
	sqliteAll(handle: number, sql: string, params: NativeSqliteValue[]): Record<string, NativeSqliteValue>[];
	sqliteClose(handle: number): void;
	/** Bytes of a file the host ships next to the bundle (such as `quickjs.wasm`), by plain name; null when missing. */
	readResource(name: string): Uint8Array | null;
	/** Sends one JSON event to the Swift side (UI, test drivers). */
	emit(json: string): void;
	/** Calls the Swift handler `name` with JSON arguments; the answer arrives through `__piHost.hostResult(id, ...)`. */
	hostCall(id: number, name: string, json: string): void;
}

export interface HostCallbacks {
	fireTimer(id: number): void;
	fetchEvent(id: number, type: "response" | "chunk" | "end" | "error", payload: unknown): void;
	/** Settles a `hostCall`: `json` is the handler's JSON result, or its error message when `ok` is false. */
	hostResult(id: number, ok: boolean, json: string): void;
}

declare global {
	// eslint-disable-next-line no-var
	var __native: NativeBindings;
	// eslint-disable-next-line no-var
	var __piHost: HostCallbacks;
}

export const native: NativeBindings = globalThis.__native;
