// fetch over Swift URLSession. The response body is a ReadableStream fed by native chunk events,
// so pi-ai's SSE parsing sees bytes as they arrive. Abort cancels the URLSession task.

import { native } from "./native.ts";

type FetchEventHandler = (type: "response" | "chunk" | "end" | "error", payload: unknown) => void;

/** Live requests by id; `__piHost.fetchEvent` dispatches into this map. */
export const fetchHandlers = new Map<number, FetchEventHandler>();
let nextFetchId = 1;

/**
 * Network counters, so measurements can tell network chunking apart from Pi's throttled partials.
 * `requests` and `bytes` only grow; `chunks` and the chunk times restart when a caller zeroes `chunks`.
 */
export const fetchStats = { requests: 0, chunks: 0, bytes: 0, firstChunkAt: 0, lastChunkAt: 0 };

type HeadersInit = Headers | Record<string, string> | Iterable<readonly [string, string]>;

function normalizeName(name: string): string {
	const n = String(name).toLowerCase();
	if (!/^[!#$%&'*+\-.^_`|~0-9a-z]+$/.test(n)) throw new TypeError(`Invalid header name: "${name}"`);
	return n;
}

function normalizeValue(value: string): string {
	return String(value).replace(/^[\t\n\r ]+|[\t\n\r ]+$/g, "");
}

class HeadersPolyfill {
	#map = new Map<string, string[]>();

	constructor(init?: HeadersInit) {
		if (init === undefined || init === null) return;
		if (init instanceof HeadersPolyfill) {
			for (const [k, v] of init.#map) this.#map.set(k, [...v]);
		} else if (typeof (init as Iterable<unknown>)[Symbol.iterator] === "function") {
			for (const pair of init as Iterable<readonly [string, string]>) {
				if (pair.length !== 2) throw new TypeError("Header pairs must have two items");
				this.append(pair[0], pair[1]);
			}
		} else {
			for (const [k, v] of Object.entries(init as Record<string, string>)) this.append(k, v);
		}
	}

	append(name: string, value: string): void {
		const key = normalizeName(name);
		const list = this.#map.get(key);
		if (list === undefined) this.#map.set(key, [normalizeValue(value)]);
		else list.push(normalizeValue(value));
	}
	set(name: string, value: string): void {
		this.#map.set(normalizeName(name), [normalizeValue(value)]);
	}
	get(name: string): string | null {
		const list = this.#map.get(normalizeName(name));
		return list === undefined ? null : list.join(", ");
	}
	getSetCookie(): string[] {
		return [...(this.#map.get("set-cookie") ?? [])];
	}
	has(name: string): boolean {
		return this.#map.has(normalizeName(name));
	}
	delete(name: string): void {
		this.#map.delete(normalizeName(name));
	}
	forEach(callback: (value: string, key: string, parent: HeadersPolyfill) => void, thisArg?: unknown): void {
		for (const [k, v] of this.entries()) callback.call(thisArg, v, k, this);
	}
	*entries(): IterableIterator<[string, string]> {
		for (const key of [...this.#map.keys()].sort()) {
			if (key === "set-cookie") for (const v of this.#map.get(key)!) yield [key, v];
			else yield [key, this.#map.get(key)!.join(", ")];
		}
	}
	*keys(): IterableIterator<string> {
		for (const [k] of this.entries()) yield k;
	}
	*values(): IterableIterator<string> {
		for (const [, v] of this.entries()) yield v;
	}
	[Symbol.iterator](): IterableIterator<[string, string]> {
		return this.entries();
	}
	get [Symbol.toStringTag](): string {
		return "Headers";
	}
}

// ---- Blob, File, FormData (enough for SDK type checks and small bodies) ----

type BlobPart = string | ArrayBuffer | ArrayBufferView | BlobPolyfill;

function concatBytes(chunks: Uint8Array[]): Uint8Array {
	let length = 0;
	for (const c of chunks) length += c.length;
	const out = new Uint8Array(length);
	let offset = 0;
	for (const c of chunks) {
		out.set(c, offset);
		offset += c.length;
	}
	return out;
}

class BlobPolyfill {
	readonly #bytes: Uint8Array;
	readonly type: string;
	constructor(parts: BlobPart[] = [], options: { type?: string } = {}) {
		const chunks: Uint8Array[] = [];
		for (const part of parts) {
			if (typeof part === "string") chunks.push(native.utf8Encode(part));
			else if (part instanceof BlobPolyfill) chunks.push(part.#bytes);
			else if (part instanceof ArrayBuffer) chunks.push(new Uint8Array(part.slice(0)));
			else if (ArrayBuffer.isView(part)) chunks.push(new Uint8Array(part.buffer, part.byteOffset, part.byteLength).slice());
			else chunks.push(native.utf8Encode(String(part)));
		}
		this.#bytes = concatBytes(chunks);
		this.type = (options.type ?? "").toLowerCase();
	}
	get size(): number {
		return this.#bytes.length;
	}
	async arrayBuffer(): Promise<ArrayBuffer> {
		return this.#bytes.slice().buffer as ArrayBuffer;
	}
	async bytes(): Promise<Uint8Array> {
		return this.#bytes.slice();
	}
	async text(): Promise<string> {
		return new TextDecoder().decode(this.#bytes);
	}
	slice(start?: number, end?: number, type?: string): BlobPolyfill {
		return new BlobPolyfill([this.#bytes.slice(start, end)], { type: type ?? this.type });
	}
	stream(): ReadableStream<Uint8Array> {
		const bytes = this.#bytes.slice();
		return new ReadableStream({
			start(controller) {
				if (bytes.length > 0) controller.enqueue(bytes);
				controller.close();
			},
		});
	}
	get [Symbol.toStringTag](): string {
		return "Blob";
	}
}

class FilePolyfill extends BlobPolyfill {
	readonly name: string;
	readonly lastModified: number;
	constructor(parts: BlobPart[], name: string, options: { type?: string; lastModified?: number } = {}) {
		super(parts, options);
		this.name = String(name);
		this.lastModified = options.lastModified ?? Date.now();
	}
	override get [Symbol.toStringTag](): string {
		return "File";
	}
}

class FormDataPolyfill {
	#entries: [string, string | FilePolyfill][] = [];
	append(name: string, value: string | BlobPolyfill, filename?: string): void {
		this.#entries.push([String(name), toFormValue(value, filename)]);
	}
	set(name: string, value: string | BlobPolyfill, filename?: string): void {
		this.delete(name);
		this.append(name, value, filename);
	}
	get(name: string): string | FilePolyfill | null {
		return this.#entries.find(([k]) => k === name)?.[1] ?? null;
	}
	getAll(name: string): (string | FilePolyfill)[] {
		return this.#entries.filter(([k]) => k === name).map(([, v]) => v);
	}
	has(name: string): boolean {
		return this.#entries.some(([k]) => k === name);
	}
	delete(name: string): void {
		this.#entries = this.#entries.filter(([k]) => k !== name);
	}
	*entries(): IterableIterator<[string, string | FilePolyfill]> {
		yield* this.#entries;
	}
	[Symbol.iterator](): IterableIterator<[string, string | FilePolyfill]> {
		return this.entries();
	}
}

function toFormValue(value: string | BlobPolyfill, filename?: string): string | FilePolyfill {
	if (value instanceof FilePolyfill && filename === undefined) return value;
	if (value instanceof BlobPolyfill) return new FilePolyfill([value], filename ?? "blob", { type: value.type });
	return String(value);
}

// ---- bodies --------------------------------------------------------------

type BodyInit = string | ArrayBuffer | ArrayBufferView | BlobPolyfill | URLSearchParams | ReadableStream<Uint8Array>;

function extractBody(body: BodyInit | null | undefined): {
	stream: ReadableStream<Uint8Array> | null;
	bytes: Uint8Array | null;
	contentType: string | null;
} {
	if (body === null || body === undefined) return { stream: null, bytes: null, contentType: null };
	if (body instanceof ReadableStream) return { stream: body, bytes: null, contentType: null };
	let bytes: Uint8Array;
	let contentType: string | null = null;
	if (typeof body === "string") {
		bytes = native.utf8Encode(body);
		contentType = "text/plain;charset=UTF-8";
	} else if (body instanceof URLSearchParams) {
		bytes = native.utf8Encode(body.toString());
		contentType = "application/x-www-form-urlencoded;charset=UTF-8";
	} else if (body instanceof BlobPolyfill) {
		// Blob bytes are private; read them through a synchronous copy of the same parts.
		const stream = body.stream();
		return { stream, bytes: null, contentType: body.type || null };
	} else if (body instanceof ArrayBuffer) {
		bytes = new Uint8Array(body.slice(0));
	} else if (ArrayBuffer.isView(body)) {
		bytes = new Uint8Array(body.buffer, body.byteOffset, body.byteLength).slice();
	} else {
		bytes = native.utf8Encode(String(body));
		contentType = "text/plain;charset=UTF-8";
	}
	const copy = bytes;
	const stream = new ReadableStream<Uint8Array>({
		start(controller) {
			if (copy.length > 0) controller.enqueue(copy);
			controller.close();
		},
	});
	return { stream, bytes, contentType };
}

async function readAll(stream: ReadableStream<Uint8Array> | null): Promise<Uint8Array> {
	if (stream === null) return new Uint8Array(0);
	const reader = stream.getReader();
	const chunks: Uint8Array[] = [];
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		chunks.push(value instanceof Uint8Array ? value : new Uint8Array(value as ArrayBufferLike));
	}
	return concatBytes(chunks);
}

abstract class BodyMixin {
	protected _body: ReadableStream<Uint8Array> | null = null;
	protected _bytes: Uint8Array | null = null;
	#used = false;

	get body(): ReadableStream<Uint8Array> | null {
		return this._body;
	}
	get bodyUsed(): boolean {
		return this.#used;
	}
	protected async consume(): Promise<Uint8Array> {
		if (this.#used) throw new TypeError("Body has already been consumed");
		this.#used = true;
		if (this._bytes !== null) return this._bytes;
		return readAll(this._body);
	}
	async arrayBuffer(): Promise<ArrayBuffer> {
		const bytes = await this.consume();
		return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
	}
	async bytes(): Promise<Uint8Array> {
		return this.consume();
	}
	async text(): Promise<string> {
		return new TextDecoder().decode(await this.consume());
	}
	async json(): Promise<unknown> {
		return JSON.parse(await this.text());
	}
	async blob(): Promise<BlobPolyfill> {
		return new BlobPolyfill([await this.consume()]);
	}
	async formData(): Promise<never> {
		throw new TypeError("formData() is not supported");
	}
}

// ---- Request / Response --------------------------------------------------

type RequestInit = {
	method?: string;
	headers?: HeadersInit;
	body?: BodyInit | null;
	signal?: AbortSignal | null;
	redirect?: string;
	duplex?: string;
	[key: string]: unknown;
};

class RequestPolyfill extends BodyMixin {
	readonly url: string;
	readonly method: string;
	readonly headers: HeadersPolyfill;
	readonly signal: AbortSignal;
	readonly redirect: string;

	constructor(input: string | URL | RequestPolyfill, init: RequestInit = {}) {
		super();
		const source = input instanceof RequestPolyfill ? input : null;
		this.url = source ? source.url : new URL(String(input)).href;
		this.method = String(init.method ?? source?.method ?? "GET").toUpperCase();
		this.headers = new HeadersPolyfill(init.headers ?? source?.headers);
		this.signal = init.signal ?? source?.signal ?? new AbortController().signal;
		this.redirect = init.redirect ?? source?.redirect ?? "follow";
		const body = init.body !== undefined ? init.body : null;
		if (body !== null && (this.method === "GET" || this.method === "HEAD")) {
			throw new TypeError("Request with GET/HEAD method cannot have body");
		}
		if (body !== null) {
			const extracted = extractBody(body);
			this._body = extracted.stream;
			this._bytes = extracted.bytes;
			if (extracted.contentType !== null && !this.headers.has("content-type")) {
				this.headers.set("content-type", extracted.contentType);
			}
		} else if (source !== null) {
			this._body = source._body;
			this._bytes = source._bytes;
		}
	}

	clone(): RequestPolyfill {
		return new RequestPolyfill(this);
	}
}

type ResponseInit = { status?: number; statusText?: string; headers?: HeadersInit };

class ResponsePolyfill extends BodyMixin {
	readonly status: number;
	readonly statusText: string;
	readonly headers: HeadersPolyfill;
	readonly type: string = "default";
	url = "";
	redirected = false;

	constructor(body?: BodyInit | null, init: ResponseInit = {}) {
		super();
		this.status = init.status ?? 200;
		if (this.status < 200 || this.status > 599) throw new RangeError(`Invalid response status ${this.status}`);
		this.statusText = init.statusText ?? "";
		this.headers = new HeadersPolyfill(init.headers);
		const extracted = extractBody(body);
		this._body = extracted.stream;
		this._bytes = extracted.bytes;
		if (extracted.contentType !== null && !this.headers.has("content-type")) {
			this.headers.set("content-type", extracted.contentType);
		}
	}

	get ok(): boolean {
		return this.status >= 200 && this.status < 300;
	}

	clone(): ResponsePolyfill {
		if (this.bodyUsed) throw new TypeError("Response body is already used");
		let cloneBody: ReadableStream<Uint8Array> | null = null;
		if (this._body !== null) {
			const [a, b] = this._body.tee();
			this._body = a;
			cloneBody = b;
		}
		const copy = new ResponsePolyfill(null, { status: this.status, statusText: this.statusText, headers: this.headers });
		copy._body = cloneBody;
		copy._bytes = this._bytes;
		copy.url = this.url;
		return copy;
	}

	static json(data: unknown, init: ResponseInit = {}): ResponsePolyfill {
		const headers = new HeadersPolyfill(init.headers);
		if (!headers.has("content-type")) headers.set("content-type", "application/json");
		return new ResponsePolyfill(JSON.stringify(data), { ...init, headers });
	}

	static error(): ResponsePolyfill {
		const response = new ResponsePolyfill(null, { status: 200 });
		(response as { status: number }).status = 0;
		return response;
	}

	/** @internal Wraps a native response whose body arrives as chunks. */
	static _native(
		status: number,
		statusText: string,
		headers: [string, string][],
		url: string,
		body: ReadableStream<Uint8Array> | null,
	): ResponsePolyfill {
		const response = new ResponsePolyfill(null, { headers });
		(response as { status: number }).status = status;
		(response as { statusText: string }).statusText = statusText;
		response._body = body;
		response.url = url;
		return response;
	}
}

// ---- fetch ---------------------------------------------------------------

function abortError(signal: AbortSignal): unknown {
	return signal.reason ?? new DOMException("This operation was aborted", "AbortError");
}

async function fetchPolyfill(input: string | URL | RequestPolyfill, init?: RequestInit): Promise<ResponsePolyfill> {
	const request = new RequestPolyfill(input, init);
	const signal = request.signal;
	if (signal.aborted) throw abortError(signal);
	const url = new URL(request.url);
	if (url.protocol !== "https:" && url.protocol !== "http:") {
		throw new TypeError(`fetch: unsupported protocol ${url.protocol}`);
	}
	const bodyBytes = request.body === null ? null : await readAll(request.body);
	const id = nextFetchId++;
	fetchStats.requests++;

	return new Promise<ResponsePolyfill>((resolve, reject) => {
		let controller: ReadableStreamDefaultController<Uint8Array> | null = null;
		let settled = false;
		let finished = false;

		const finish = () => {
			finished = true;
			fetchHandlers.delete(id);
			signal.removeEventListener("abort", onAbort);
		};
		const onAbort = () => {
			if (finished) return;
			native.fetchCancel(id);
			const error = abortError(signal);
			finish();
			if (!settled) {
				settled = true;
				reject(error);
			} else {
				try {
					controller?.error(error);
				} catch {}
			}
		};
		signal.addEventListener("abort", onAbort);

		fetchHandlers.set(id, (type, payload) => {
			if (finished) return;
			switch (type) {
				case "response": {
					const p = payload as { status: number; statusText: string; headers: [string, string][]; url: string };
					const body =
						request.method === "HEAD" || p.status === 204 || p.status === 304
							? null
							: new ReadableStream<Uint8Array>({
									start(c) {
										controller = c;
									},
									cancel() {
										if (!finished) {
											native.fetchCancel(id);
											finish();
										}
									},
								});
					settled = true;
					resolve(ResponsePolyfill._native(p.status, p.statusText, p.headers, p.url, body));
					break;
				}
				case "chunk":
					fetchStats.lastChunkAt = performance.now();
					if (fetchStats.chunks++ === 0) fetchStats.firstChunkAt = fetchStats.lastChunkAt;
					fetchStats.bytes += (payload as Uint8Array).byteLength;
					controller?.enqueue(payload as Uint8Array);
					break;
				case "end":
					finish();
					try {
						controller?.close();
					} catch {}
					break;
				case "error": {
					finish();
					const error = new TypeError(`fetch failed: ${String(payload)}`);
					if (!settled) {
						settled = true;
						reject(error);
					} else {
						try {
							controller?.error(error);
						} catch {}
					}
					break;
				}
			}
		});

		native.fetchStart(id, {
			url: request.url,
			method: request.method,
			headers: [...request.headers.entries()],
			body: bodyBytes,
		});
	});
}

export function installFetch(define: (name: string, value: unknown) => void): void {
	define("Headers", HeadersPolyfill);
	define("Request", RequestPolyfill);
	define("Response", ResponsePolyfill);
	define("Blob", BlobPolyfill);
	define("File", FilePolyfill);
	define("FormData", FormDataPolyfill);
	define("fetch", fetchPolyfill);
}
