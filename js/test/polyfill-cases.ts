// Behaviour checks for the host polyfills, run inside JSC (where they are the real globals).

import type { StorageConformanceAssertions } from "@earendil-works/pi-durable/testing";

type Case = { name: string; run(): Promise<void> };

export function createPolyfillCases(t: StorageConformanceAssertions): Case[] {
	return [
		{
			name: "TextEncoder/TextDecoder round-trip, BOM, and split multi-byte sequences when streaming",
			async run() {
				const text = "aé€😀z";
				const bytes = new TextEncoder().encode(text);
				t.deepEqual([...bytes], [97, 195, 169, 226, 130, 172, 240, 159, 152, 128, 122]);
				t.strictEqual(new TextDecoder().decode(bytes), text);
				const decoder = new TextDecoder();
				let out = "";
				for (const b of bytes) out += decoder.decode(new Uint8Array([b]), { stream: true });
				out += decoder.decode();
				t.strictEqual(out, text);
				t.strictEqual(new TextDecoder().decode(new Uint8Array([0xef, 0xbb, 0xbf, 0x41])), "A");
				t.strictEqual(new TextDecoder().decode(new Uint8Array([0xff])), "�");
				let threw = false;
				try {
					new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array([0xff]));
				} catch {
					threw = true;
				}
				t.ok(threw, "fatal decoder throws on invalid UTF-8");
				const into = new Uint8Array(4);
				t.deepEqual(new TextEncoder().encodeInto("é€", into), { read: 1, written: 2 });
			},
		},
		{
			name: "timers fire in order; clearTimeout and setInterval work",
			async run() {
				const order: number[] = [];
				setTimeout(() => order.push(2), 20);
				setTimeout(() => order.push(1), 5);
				const cancelled = setTimeout(() => order.push(99), 10);
				clearTimeout(cancelled);
				let ticks = 0;
				const interval = setInterval(() => {
					if (++ticks === 3) clearInterval(interval);
				}, 2);
				await new Promise((resolve) => setTimeout(resolve, 60));
				t.deepEqual(order, [1, 2]);
				t.strictEqual(ticks, 3);
				const handle = setTimeout(() => {}, 1) as unknown as { unref?: () => unknown };
				t.ok(typeof handle.unref === "function", "Node-style unref exists");
			},
		},
		{
			name: "queueMicrotask runs before timers",
			async run() {
				const order: string[] = [];
				setTimeout(() => order.push("timer"), 0);
				queueMicrotask(() => order.push("micro"));
				await new Promise((resolve) => setTimeout(resolve, 5));
				t.deepEqual(order, ["micro", "timer"]);
			},
		},
		{
			name: "AbortController, AbortSignal.timeout and AbortSignal.any",
			async run() {
				const controller = new AbortController();
				let events = 0;
				controller.signal.addEventListener("abort", () => events++);
				controller.abort();
				controller.abort();
				t.ok(controller.signal.aborted);
				t.strictEqual(events, 1);
				t.strictEqual((controller.signal.reason as DOMException).name, "AbortError");
				const timed = AbortSignal.timeout(5);
				await new Promise((resolve) => setTimeout(resolve, 20));
				t.strictEqual((timed.reason as DOMException).name, "TimeoutError");
				const a = new AbortController();
				const b = new AbortController();
				const any = AbortSignal.any([a.signal, b.signal]);
				b.abort("why");
				t.ok(any.aborted);
				t.strictEqual(any.reason, "why");
				let threw: unknown;
				try {
					any.throwIfAborted();
				} catch (error) {
					threw = error;
				}
				t.strictEqual(threw, "why");
			},
		},
		{
			name: "structuredClone deep-copies JSON, Dates, Maps, Sets, typed arrays and cycles; rejects functions",
			async run() {
				const source: Record<string, unknown> = {
					a: [1, { b: "c" }],
					d: new Date(5),
					m: new Map([["k", { v: 1 }]]),
					s: new Set([1, 2]),
					u: new Uint8Array([1, 2, 3]),
					n: null,
					big: 10n,
				};
				source.self = source;
				const copy = structuredClone(source) as typeof source;
				t.ok(copy !== source && copy.a !== source.a);
				t.strictEqual(copy.self, copy);
				t.deepEqual((copy.d as Date).getTime(), 5);
				t.deepEqual(copy.m, source.m);
				t.ok(copy.u instanceof Uint8Array && (copy.u as Uint8Array)[2] === 3);
				t.strictEqual(copy.big, 10n);
				let threw = false;
				try {
					structuredClone({ f() {} });
				} catch (error) {
					threw = (error as DOMException).name === "DataCloneError";
				}
				t.ok(threw, "functions throw DataCloneError");
			},
		},
		{
			name: "URL and URLSearchParams",
			async run() {
				const url = new URL("/v1/messages?beta=true", "https://api.anthropic.com/");
				t.strictEqual(url.href, "https://api.anthropic.com/v1/messages?beta=true");
				t.strictEqual(url.host, "api.anthropic.com");
				url.searchParams.set("x", "a b");
				t.strictEqual(url.search, "?beta=true&x=a+b");
				t.strictEqual(new URLSearchParams({ q: "1", r: "2" }).toString(), "q=1&r=2");
			},
		},
		{
			name: "Headers, Response bodies and ReadableStream",
			async run() {
				const headers = new Headers({ "Content-Type": "application/json" });
				headers.append("x-a", "1");
				headers.append("X-A", "2");
				t.strictEqual(headers.get("x-a"), "1, 2");
				t.deepEqual([...headers.keys()], ["content-type", "x-a"]);
				const response = new Response(JSON.stringify({ ok: true }), { status: 201, headers });
				t.strictEqual(response.status, 201);
				t.deepEqual(await response.json(), { ok: true });
				const stream = new ReadableStream<Uint8Array>({
					start(controller) {
						controller.enqueue(new TextEncoder().encode("data: 1\n\n"));
						controller.enqueue(new TextEncoder().encode("data: 2\n\n"));
						controller.close();
					},
				});
				const text = await new Response(stream).text();
				t.strictEqual(text, "data: 1\n\ndata: 2\n\n");
				const decoded: string[] = [];
				const source = new Response("héllo").body!.pipeThrough(new TextDecoderStream());
				for await (const chunk of source as unknown as AsyncIterable<string>) decoded.push(chunk);
				t.strictEqual(decoded.join(""), "héllo");
			},
		},
		{
			name: "crypto.getRandomValues and randomUUID",
			async run() {
				const bytes = crypto.getRandomValues(new Uint8Array(32));
				t.ok(bytes.some((b) => b !== 0), "random bytes are not all zero");
				t.ok(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(crypto.randomUUID()));
			},
		},
		{
			name: "WebAssembly.compile and instantiate settle on the JS queue",
			async run() {
				// (module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
				const bytes = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 127, 127, 1, 127, 3, 2, 1, 0, 7, 7, 1, 3, 97, 100, 100, 0, 0, 10, 9, 1, 7, 0, 32, 0, 32, 1, 106, 11]);
				const module = await WebAssembly.compile(bytes);
				const instance = await WebAssembly.instantiate(module, {});
				t.strictEqual((instance.exports.add as (a: number, b: number) => number)(2, 3), 5);
				const both = await WebAssembly.instantiate(bytes, {});
				t.strictEqual((both.instance.exports.add as (a: number, b: number) => number)(4, 5), 9);
				// JSC will not pin wasm memory; the host reads and fills views into it through copies (QuickJS's strings).
				const memory = new WebAssembly.Memory({ initial: 1 });
				new Uint8Array(memory.buffer).set([104, 105, 33], 10);
				t.strictEqual(new TextDecoder().decode(new Uint8Array(memory.buffer, 10, 3)), "hi!");
				const random = crypto.getRandomValues(new Uint8Array(memory.buffer, 100, 32));
				t.ok(random.some((b) => b !== 0), "random bytes land in wasm memory");
			},
		},
		{
			name: "atob/btoa, performance.now and Intl",
			async run() {
				t.strictEqual(btoa("hello"), "aGVsbG8=");
				t.strictEqual(atob("aGVsbG8="), "hello");
				const a = performance.now();
				await new Promise((resolve) => setTimeout(resolve, 5));
				t.ok(performance.now() - a >= 4, "performance.now advances");
				t.ok(new Intl.DateTimeFormat("en-US", { timeZone: "UTC" }).format(new Date(0)).includes("1970"));
				t.strictEqual(new Intl.NumberFormat("en-US").format(1234.5), "1,234.5");
				t.ok(typeof Intl.Segmenter === "function", "Intl.Segmenter exists");
			},
		},
		{
			name: "fetch rejects non-http URLs and an already-aborted signal",
			async run() {
				await t.rejects(fetch("file:///etc/hosts"), "unsupported protocol");
				await t.rejects(fetch("https://example.com", { signal: AbortSignal.abort() }), "aborted");
			},
		},
	];
}
