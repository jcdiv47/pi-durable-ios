// The HTTP endpoint tools (src/app/http.ts) without a network: URL building and its refusals, read versus write, the
// trust check, and how responses are formatted and capped. Run inside JSC (and under Bun).

import type { EntryRecord } from "@earendil-works/pi-durable";
import type { StorageConformanceAssertions } from "@earendil-works/pi-durable/testing";
import { defaultPolicies } from "../src/app/approvals.ts";
import {
	displayUrl,
	formatResponse,
	type HttpEndpointConfig,
	httpSettings,
	HttpTools,
	httpTrusted,
	isRead,
	MAX_BODY_CHARS,
	MAX_READ_BYTES,
	performRequest,
	requestBody,
	requestHeaders,
	requestUrl,
} from "../src/app/http.ts";

type Case = { name: string; run(): Promise<void> };

const ha: HttpEndpointConfig = {
	id: "ha",
	name: "Home Assistant",
	baseUrl: "http://100.64.0.2:8123/api",
	description: "Home Assistant's REST API. GET states/<entity_id> reads one entity.",
	enabled: true,
	ready: true,
	needsVpn: true,
	readWithoutAsking: true,
	auth: "bearer",
};
const ntfy: HttpEndpointConfig = {
	id: "ntfy",
	name: "ntfy",
	baseUrl: "https://ntfy.example.com/alerts/",
	description: "",
	enabled: true,
	ready: true,
	auth: "query",
	authName: "auth",
};
const n8n: HttpEndpointConfig = { ...ntfy, id: "n8n", name: "n8n", baseUrl: "https://n8n.example.com", auth: "header", authName: "X-N8N-Key" };

function refuses(t: StorageConformanceAssertions, run: () => unknown, includes: string): void {
	try {
		run();
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		t.ok(message.includes(includes), `expected "${includes}" in "${message}"`);
		return;
	}
	t.ok(false, `expected a refusal including "${includes}"`);
}

const entry = (kind: string, toolName?: string) => ({ kind, model: toolName ? [{ toolName }] : [] }) as unknown as EntryRecord;

function response(body: string | Uint8Array, init: ResponseInit = {}): Response {
	return new Response(body as BodyInit, init);
}

export function createHttpCases(t: StorageConformanceAssertions): Case[] {
	return [
		{
			name: "URLs: the path goes under the base, the query is appended, query auth is the placeholder",
			async run() {
				t.strictEqual(requestUrl(ha, "states/light.kitchen").href, "http://100.64.0.2:8123/api/states/light.kitchen");
				t.strictEqual(requestUrl(ha, "/states").href, "http://100.64.0.2:8123/api/states");
				t.strictEqual(requestUrl(ha, "").href, "http://100.64.0.2:8123/api");
				t.strictEqual(requestUrl(ha, "history/period/", { filter_entity_id: "a b" }).href, "http://100.64.0.2:8123/api/history/period/?filter_entity_id=a+b");
				t.strictEqual(requestUrl(n8n, "webhook/x").href, "https://n8n.example.com/webhook/x");
				const url = requestUrl(ntfy, "up", { auth: "mine", title: "Hi" });
				// The endpoint's auth wins over the model's.
				t.strictEqual(url.searchParams.get("auth"), "pi-host-key:http-ntfy");
				t.strictEqual(url.searchParams.getAll("auth").length, 1);
				t.strictEqual(displayUrl(ntfy, url), "https://ntfy.example.com/alerts/up?title=Hi");
			},
		},
		{
			name: "URLs: anything that could leave the base is refused",
			async run() {
				refuses(t, () => requestUrl(ha, "https://evil.example/x"), "relative");
				refuses(t, () => requestUrl(ha, "//evil.example/x"), "relative");
				refuses(t, () => requestUrl(ha, "javascript:alert(1)"), "relative");
				refuses(t, () => requestUrl(ha, "user@evil.example"), '"@"');
				refuses(t, () => requestUrl(ha, "states\\..\\admin"), "backslash");
				refuses(t, () => requestUrl(ha, "../admin"), '".."');
				refuses(t, () => requestUrl(ha, "states/./x"), '"."');
				refuses(t, () => requestUrl(ha, "%2e%2e/admin"), '".."');
				refuses(t, () => requestUrl(ha, "%2E%2e/admin"), '".."');
				refuses(t, () => requestUrl(ha, "states%2F..%2Fadmin"), "encoded slashes");
				refuses(t, () => requestUrl(ha, "states%5cx"), "encoded slashes");
				refuses(t, () => requestUrl(ha, "states?x=1"), "query");
				refuses(t, () => requestUrl(ha, "%zz"), "percent-encoding");
				refuses(t, () => requestUrl(ha, "a\nb"), "control");
				refuses(t, () => requestUrl(ha, "x/pi-host-key:openai"), "pi-host-key:");
				refuses(t, () => requestUrl(ha, "x/pi-host-key%3Aopenai"), "pi-host-key:");
				refuses(t, () => requestUrl(ha, "x", { q: "PI-HOST-KEY:openai" }), "pi-host-key:");
				refuses(t, () => requestUrl(ha, "x", { "pi-host-key:openai": "1" }), "pi-host-key:");
			},
		},
		{
			name: "Bodies and headers: json or text, typed; the model sets no header; placeholders refused",
			async run() {
				t.deepEqual(requestBody({ json: { entity_id: "light.kitchen" } }), { body: '{"entity_id":"light.kitchen"}', contentType: "application/json" });
				t.deepEqual(requestBody({ body: "Backup done" }), { body: "Backup done", contentType: "text/plain; charset=utf-8" });
				t.deepEqual(requestBody({ body: '{"a":1}' }), { body: '{"a":1}', contentType: "application/json" });
				t.deepEqual(requestBody({ body: "a=1", content_type: "application/x-www-form-urlencoded" }).contentType, "application/x-www-form-urlencoded");
				t.deepEqual(requestBody({}), {});
				refuses(t, () => requestBody({ body: "x", json: {} }), "not both");
				refuses(t, () => requestBody({ body: "x", content_type: "text/html\r\nX-Evil: 1" }), "content_type");
				refuses(t, () => requestBody({ json: { key: "pi-host-key:openai" } }), "pi-host-key:");
				t.deepEqual(requestHeaders(ha), { accept: "application/json, text/*;q=0.9, */*;q=0.5", authorization: "Bearer pi-host-key:http-ha" });
				t.strictEqual(requestHeaders(n8n, "application/json")["x-n8n-key"], "pi-host-key:http-n8n");
				t.strictEqual(requestHeaders(ntfy).authorization, undefined);
			},
		},
		{
			name: "Reads and writes: GET and HEAD are http_get's and replay-safe; the rest are http_send's and ask",
			async run() {
				t.ok(isRead("GET") && isRead("head"));
				t.ok(!isRead("POST") && !isRead("DELETE") && !isRead("PATCH") && !isRead("PUT"));
				const get = HttpTools.tools!.find((tool) => tool.name === "http_get")!;
				const send = HttpTools.tools!.find((tool) => tool.name === "http_send")!;
				t.strictEqual(get.replay, "safe");
				t.strictEqual(send.replay, "unsafe");
				t.strictEqual(defaultPolicies.http_get, "ask");
				t.strictEqual(defaultPolicies.http_send, "ask");
			},
		},
		{
			name: "Trust: a read skips the ask only on an endpoint that allows it, on and set up, with no outside text",
			async run() {
				httpSettings.endpoints = [ha, { ...ntfy, readWithoutAsking: false }];
				const clean = [entry("pi.user"), entry("pi.tool-result", "http_get"), entry("pi.tool-result", "ssh_exec")];
				t.ok(httpTrusted("http_get", { endpoint: "ha", path: "states" }, clean));
				t.ok(httpTrusted("http_get", { endpoint: "ha", path: "states", method: "HEAD" }, clean));
				t.ok(!httpTrusted("http_send", { endpoint: "ha", path: "services/light/turn_on", method: "POST" }, clean), "writes always ask");
				t.ok(!httpTrusted("http_get", { endpoint: "ha", path: "x", method: "POST" }, clean));
				t.ok(!httpTrusted("http_get", { endpoint: "ntfy", path: "x" }, clean), "the endpoint doesn't allow it");
				t.ok(!httpTrusted("http_get", { endpoint: "nope", path: "x" }, clean));
				for (const outside of ["web_search", "web_fetch", "codemode", "mcp__ha__get_state"]) {
					t.ok(!httpTrusted("http_get", { endpoint: "ha", path: "x" }, [...clean, entry("pi.tool-result", outside)]), outside);
				}
				httpSettings.endpoints = [{ ...ha, enabled: false }];
				t.ok(!httpTrusted("http_get", { endpoint: "ha", path: "x" }, clean), "turned off");
				httpSettings.endpoints = [{ ...ha, ready: false }];
				t.ok(!httpTrusted("http_get", { endpoint: "ha", path: "x" }, clean), "no secret saved");
				httpSettings.endpoints = [];
			},
		},
		{
			name: "Responses: status, a few headers, text bodies; binary described; long bodies cut",
			async run() {
				const base = { method: "GET", url: "http://100.64.0.2:8123/api/states", statusText: "OK", cut: false };
				const json = formatResponse(ha, {
					...base,
					status: 200,
					headers: new Headers({ "content-type": "application/json", "set-cookie": "s=1", "x-other": "1" }),
					body: new TextEncoder().encode('{"state":"on"}'),
				});
				t.ok(json.startsWith("Endpoint: ha (Home Assistant)\nGET http://100.64.0.2:8123/api/states\nHTTP 200 OK\ncontent-type: application/json\n"), json);
				t.ok(json.includes('"state": "on"'), json);
				t.ok(!json.includes("set-cookie") && !json.includes("x-other"), json);

				const image = formatResponse(ha, { ...base, status: 200, headers: new Headers({ "content-type": "image/png" }), body: new Uint8Array([137, 80, 78, 71, 0]) });
				t.ok(image.includes("(image/png body, 5 bytes: not text, so not shown)"), image);

				const long = "x".repeat(MAX_BODY_CHARS + 10);
				const cut = formatResponse(ha, { ...base, status: 200, headers: new Headers({ "content-type": "text/plain" }), body: new TextEncoder().encode(long) });
				t.ok(cut.endsWith(`[Cut at 24,000 of ${(MAX_BODY_CHARS + 10).toLocaleString("en-US")} characters]`), cut.slice(-80));

				const moved = formatResponse(ha, { ...base, status: 302, statusText: "Found", headers: new Headers({ location: "https://evil.example/" }), body: new Uint8Array(0) });
				t.ok(moved.includes("HTTP 302 Found\nlocation: https://evil.example/\nRedirects are not followed."), moved);
				const missing = formatResponse(ha, { ...base, status: 404, statusText: "Not Found", headers: new Headers({ "content-type": "text/plain" }), body: new TextEncoder().encode("no entity") });
				t.ok(missing.includes("HTTP 404 Not Found") && missing.endsWith("no entity"), missing);
			},
		},
		{
			name: "Requests: built, sent unredirected, capped, and failures named",
			async run() {
				httpSettings.endpoints = [ha, ntfy];
				const sent: { url: string; init: RequestInit }[] = [];
				let reply: () => Response = () => response('{"ok":true}', { headers: { "content-type": "application/json" } });
				const fake = (async (url: string, init: RequestInit) => {
					sent.push({ url, init });
					return reply();
				}) as unknown as typeof fetch;

				const read = await performRequest({ endpoint: "ha", path: "states" }, "GET", undefined, fake);
				t.ok(read.includes('"ok": true'), read);
				t.strictEqual(sent[0]!.url, "http://100.64.0.2:8123/api/states");
				t.strictEqual(sent[0]!.init.redirect, "manual");
				t.strictEqual(sent[0]!.init.body, undefined);
				t.strictEqual((sent[0]!.init.headers as Record<string, string>).authorization, "Bearer pi-host-key:http-ha");

				await performRequest({ endpoint: "ntfy", path: "", body: "Backup done" }, "POST", undefined, fake);
				t.strictEqual(sent[1]!.url, "https://ntfy.example.com/alerts/?auth=pi-host-key%3Ahttp-ntfy");
				t.strictEqual(sent[1]!.init.method, "POST");
				t.strictEqual(sent[1]!.init.body, "Backup done");

				await t.rejects(performRequest({ endpoint: "ha", path: "x", body: "b" }, "GET", undefined, fake), "no body");
				await t.rejects(performRequest({ endpoint: "nas", path: "x" }, "GET", undefined, fake), "No HTTP endpoint nas");

				reply = () => response(new Uint8Array(MAX_READ_BYTES + 100).fill(65), { headers: { "content-type": "text/plain" } });
				const big = await performRequest({ endpoint: "ha", path: "big" }, "GET", undefined, fake);
				t.ok(big.includes(`more than ${MAX_READ_BYTES.toLocaleString("en-US")} characters`), big.slice(-100));

				reply = () => {
					throw new TypeError("fetch failed: Could not connect to the server.");
				};
				await t.rejects(performRequest({ endpoint: "ha", path: "x" }, "GET", undefined, fake), "The VPN may be off.");
				reply = () => {
					throw new TypeError("fetch failed: No API key configured for http-ha");
				};
				await t.rejects(performRequest({ endpoint: "ha", path: "x" }, "GET", undefined, fake), "Settings › HTTP Endpoints");
				reply = () => {
					throw new TypeError("fetch failed: API key for http-ha may not be sent to evil.example");
				};
				await t.rejects(performRequest({ endpoint: "ha", path: "x" }, "GET", undefined, fake), "goes only to URLs under");

				httpSettings.endpoints = [{ ...ha, enabled: false }];
				await t.rejects(performRequest({ endpoint: "ha", path: "x" }, "GET", undefined, fake), "turned off");
				httpSettings.endpoints = [];
			},
		},
	];
}
