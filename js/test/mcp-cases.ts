// The MCP connection (pi-mcp's client) and the `mcp` extension against an in-memory Streamable HTTP server, run inside
// JSC (and under Bun).

import type { StorageConformanceAssertions } from "@earendil-works/pi-durable/testing";
import type { McpOAuthState } from "@earendil-works/pi-mcp/oauth";
import {
	McpConnection,
	McpHost,
	type McpOAuthStore,
	type McpServerConfig,
	McpServerError,
	type McpStatus,
	type McpToolDefinition,
	OAUTH_REDIRECT_URL,
	outputOf,
	shorten,
} from "../src/app/mcp.ts";
import { Buffer, sha256 } from "../src/host/pi-mcp-shims.ts";

type Case = { name: string; run(): Promise<void> };

type Message = { jsonrpc: "2.0"; id?: number | string; method?: string; params?: Record<string, unknown>; result?: unknown };

const tools: McpToolDefinition[] = [
	{
		name: "get_state",
		title: "Get state",
		description: "Read an entity's state",
		inputSchema: { type: "object", properties: { entity: { type: "string" } }, required: ["entity"] },
		annotations: { readOnlyHint: true },
	},
	{
		name: "turn.on",
		description: "Turn a device on",
		inputSchema: { type: "object", properties: { entity: { type: "string" } } },
		annotations: { idempotentHint: true },
	},
	{ name: "send", description: "Send a message", inputSchema: { type: "object", properties: { to: { $ref: "#/nowhere" } } } },
];

/** A Streamable HTTP server in memory: sessions, paged `tools/list` (the second page as SSE, after a ping). */
class FakeServer {
	readonly received: { method?: string; headers: Record<string, string>; message: Message }[] = [];
	sessions = 0;
	session: string | undefined;
	/** The next request with the current session gets 404, as after a server restart. */
	forget = false;
	status: number | undefined;
	down = false;
	/** `notifications/initialized` gets no answer until the request is aborted. */
	stallInitialized = false;
	/** Requests other than POST: GET (a server-to-client stream) and DELETE (a session ended), with the session. */
	readonly other: string[] = [];

	fetch = async (url: string | URL, init: RequestInit = {}): Promise<Response> => {
		if (this.down) throw new TypeError("fetch failed: The network connection was lost.");
		if (init.method !== "POST") {
			this.other.push(`${init.method} ${new Headers(init.headers).get("mcp-session-id")}`);
			return new Response(null, { status: init.method === "GET" ? 405 : 204 });
		}
		const headers: Record<string, string> = {};
		new Headers(init.headers).forEach((v, k) => (headers[k] = v));
		const message = JSON.parse(String(init.body)) as Message;
		this.received.push({ method: message.method, headers, message });
		if (this.stallInitialized && message.method === "notifications/initialized") {
			return new Promise((_, reject) => init.signal?.addEventListener("abort", () => reject(new TypeError("aborted")), { once: true }));
		}
		if (String(url) !== "http://100.64.0.2:8123/api/mcp") return new Response("no", { status: 404 });
		if (this.status !== undefined) return new Response("Unauthorized", { status: this.status });
		if (message.method === "initialize") {
			this.session = `s${++this.sessions}`;
			return json({ jsonrpc: "2.0", id: message.id, result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "fake-ha", version: "1.0" }, instructions: "Use entity IDs." } }, { "mcp-session-id": this.session });
		}
		if (headers["mcp-session-id"] !== this.session) return new Response("bad session", { status: 400 });
		if (this.forget) {
			this.forget = false;
			this.session = undefined;
			return new Response("session not found", { status: 404 });
		}
		if (message.id === undefined) return new Response(null, { status: 202 });
		switch (message.method) {
			case "tools/list":
				if (message.params?.cursor === undefined) return json({ jsonrpc: "2.0", id: message.id, result: { tools: tools.slice(0, 2), nextCursor: "p2" } });
				return sse([
					{ jsonrpc: "2.0", method: "notifications/message", params: { level: "info" } },
					{ jsonrpc: "2.0", id: "srv-1", method: "ping" },
					{ jsonrpc: "2.0", id: message.id, result: { tools: tools.slice(2) } },
				]);
			case "tools/call": {
				const name = message.params?.name;
				if (name === "get_state") return json({ jsonrpc: "2.0", id: message.id, result: { content: [{ type: "text", text: `on: ${JSON.stringify(message.params?.arguments)}` }] } });
				if (name === "send") return json({ jsonrpc: "2.0", id: message.id, result: { content: [{ type: "text", text: "rate limited" }], isError: true } });
				return json({ jsonrpc: "2.0", id: message.id, error: { code: -32602, message: `unknown tool ${String(name)}` } });
			}
			default:
				// The client's answer to our ping.
				if (message.result !== undefined) return new Response(null, { status: 202 });
				return json({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "no" } });
		}
	};
}

function json(body: unknown, headers: Record<string, string> = {}, status = 200): Response {
	return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
}

function sse(messages: unknown[]): Response {
	const text = messages.map((m) => `event: message\ndata: ${JSON.stringify(m)}\n\n`).join("");
	const bytes = new TextEncoder().encode(text);
	const body = new ReadableStream<Uint8Array>({
		start(controller) {
			// Split mid-event, as a network would.
			controller.enqueue(bytes.slice(0, 37));
			controller.enqueue(bytes.slice(37));
			controller.close();
		},
	});
	return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

const OAUTH_MCP_URL = "https://mcp.example.com/mcp";
const AUTH = "https://auth.example.com";

/**
 * `FakeServer` behind OAuth: protected resource and authorization server metadata, dynamic registration, a token
 * endpoint that checks the PKCE verifier and rotates refresh tokens, and an MCP endpoint that wants a live access token.
 */
class FakeOAuth {
	readonly mcp = new FakeServer();
	readonly requests: string[] = [];
	/** Access tokens the MCP endpoint takes. */
	valid = new Set<string>();
	/** The `code_challenge` of the last authorization URL the test opened. */
	challenge: string | undefined;
	registrations = 0;
	issued = 0;
	refreshToken: string | undefined;

	fetch = async (input: string | URL, init: RequestInit = {}): Promise<Response> => {
		const url = new URL(String(input));
		const method = init.method ?? "GET";
		this.requests.push(`${method} ${url.origin}${url.pathname}`);
		if (url.href === OAUTH_MCP_URL) {
			const auth = new Headers(init.headers).get("authorization");
			if (auth === null || !this.valid.has(auth.replace(/^Bearer /, ""))) {
				return new Response("unauthorized", {
					status: 401,
					headers: { "www-authenticate": `Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp"` },
				});
			}
			return this.mcp.fetch("http://100.64.0.2:8123/api/mcp", init);
		}
		if (url.href === "https://mcp.example.com/.well-known/oauth-protected-resource/mcp") {
			return json({ resource: OAUTH_MCP_URL, authorization_servers: [AUTH], scopes_supported: ["tools"] });
		}
		if (url.href === `${AUTH}/.well-known/oauth-authorization-server`) {
			return json({
				issuer: AUTH,
				authorization_endpoint: `${AUTH}/authorize`,
				token_endpoint: `${AUTH}/token`,
				registration_endpoint: `${AUTH}/register`,
				response_types_supported: ["code"],
				code_challenge_methods_supported: ["S256"],
			});
		}
		if (url.href === `${AUTH}/register` && method === "POST") {
			const metadata = JSON.parse(String(init.body)) as Record<string, unknown>;
			this.registrations++;
			return new Response(JSON.stringify({ ...metadata, client_id: `client-${this.registrations}` }), {
				status: 201,
				headers: { "content-type": "application/json" },
			});
		}
		if (url.href === `${AUTH}/token` && method === "POST") {
			const form = new URLSearchParams(String(init.body));
			if (form.get("grant_type") === "authorization_code") {
				const verifier = form.get("code_verifier") ?? "";
				const challenge = Buffer.from(sha256(new TextEncoder().encode(verifier))).toString("base64url");
				if (form.get("code") !== "the-code" || challenge !== this.challenge || form.get("redirect_uri") !== OAUTH_REDIRECT_URL) {
					return json({ error: "invalid_grant", error_description: "bad code or verifier" }, {}, 400);
				}
			} else if (form.get("grant_type") !== "refresh_token" || form.get("refresh_token") !== this.refreshToken) {
				return json({ error: "invalid_grant", error_description: "bad refresh token" }, {}, 400);
			}
			this.issued++;
			const access = `at${this.issued}`;
			this.refreshToken = `rt${this.issued}`;
			this.valid.add(access);
			return json({ access_token: access, token_type: "Bearer", expires_in: 3600, refresh_token: this.refreshToken, scope: "tools" });
		}
		return new Response("not found", { status: 404 });
	};
}

/** An OAuth store in memory, in place of the Keychain. */
function memoryStore(): McpOAuthStore & { state: McpOAuthState | undefined } {
	const store = {
		state: undefined as McpOAuthState | undefined,
		load: async () => store.state,
		save: async (state: McpOAuthState) => {
			store.state = structuredClone(state);
		},
		clear: async () => {
			store.state = undefined;
		},
	};
	return store;
}

const server = (overrides: Partial<McpServerConfig> = {}): McpServerConfig => ({
	id: "ha",
	name: "Home Assistant",
	url: "http://100.64.0.2:8123/api/mcp",
	authHeader: "Authorization",
	enabled: true,
	needsVpn: true,
	...overrides,
});

async function rejects(t: StorageConformanceAssertions, promise: Promise<unknown>): Promise<unknown> {
	try {
		await promise;
	} catch (error) {
		return error;
	}
	t.ok(false, "expected a rejection");
	return undefined;
}

const noApi = {} as never;
const context = { abortSignal: undefined } as never;

export function createMcpCases(t: StorageConformanceAssertions): Case[] {
	return [
		{
			name: "long descriptions end at a paragraph, line or sentence that fits",
			async run() {
				t.strictEqual(shorten("  short  ", 100), "short");
				t.strictEqual(shorten(`${"a".repeat(60)}\n\n${"b".repeat(60)}`, 100), `${"a".repeat(60)} …`);
				t.strictEqual(shorten(`${"a".repeat(60)}. ${"b".repeat(60)}`, 100), `${"a".repeat(60)}. …`);
				t.strictEqual(shorten("x".repeat(200), 100), `${"x".repeat(99)}…`);
			},
		},
		{
			name: "connects, pages tools/list, reads SSE, answers a ping, and sends session, version and key placeholder",
			async run() {
				const fake = new FakeServer();
				const client = new McpConnection(server(), fake.fetch);
				const listed = await client.listTools();
				t.deepEqual(listed.tools.map((tool) => tool.name), ["get_state", "turn.on", "send"]);
				t.strictEqual(listed.instructions, "Use entity IDs.");
				t.strictEqual(listed.serverName, "fake-ha");
				// The ping answer is sent without waiting; let it land.
				await new Promise((resolve) => setTimeout(resolve, 10));
				t.deepEqual(
					fake.received.map((r) => r.method ?? "response"),
					["initialize", "notifications/initialized", "tools/list", "tools/list", "response"],
				);
				t.strictEqual(fake.received[0]!.headers.authorization, "Bearer pi-host-key:mcp-ha");
				t.strictEqual(fake.received[0]!.headers["mcp-session-id"], undefined);
				t.strictEqual(fake.received[2]!.headers["mcp-session-id"], "s1");
				t.strictEqual(fake.received[2]!.headers["mcp-protocol-version"], "2025-06-18");
				t.deepEqual(fake.received[4]!.message, { jsonrpc: "2.0", id: "srv-1", result: {} });
				// No server-to-client GET stream: it would hold a connection open for notifications the app ignores.
				t.deepEqual(fake.other, []);
			},
		},
		{
			name: "a forgotten session initializes again once; a custom auth header gets the bare placeholder",
			async run() {
				const fake = new FakeServer();
				const client = new McpConnection(server({ authHeader: "X-API-Key" }), fake.fetch);
				await client.callTool("get_state", { entity: "light.desk" });
				fake.forget = true;
				const result = await client.callTool("get_state", { entity: "light.desk" });
				t.strictEqual(fake.sessions, 2);
				t.deepEqual(result.content, [{ type: "text", text: 'on: {"entity":"light.desk"}' }]);
				t.strictEqual(fake.received[0]!.headers["x-api-key"], "pi-host-key:mcp-ha");
				t.strictEqual(fake.received[0]!.headers.authorization, undefined);
				// The forgotten session is ended, as a courtesy.
				await new Promise((resolve) => setTimeout(resolve, 10));
				t.deepEqual(fake.other, ["DELETE s1"]);
			},
		},
		{
			name: "errors say what went wrong: refused token, unreachable server (with the VPN hint), JSON-RPC error",
			async run() {
				const fake = new FakeServer();
				fake.status = 401;
				const refused = await rejects(t, new McpConnection(server(), fake.fetch).listTools());
				t.ok(refused instanceof McpServerError && refused.state === "unauthorized", String(refused));
				fake.status = undefined;
				fake.down = true;
				const down = (await rejects(t, new McpConnection(server(), fake.fetch).listTools())) as McpServerError;
				t.strictEqual(down.state, "unreachable");
				t.ok(down.message.includes("100.64.0.2:8123") && down.message.includes("VPN"), down.message);
				const noVpn = (await rejects(t, new McpConnection(server({ needsVpn: false }), fake.fetch).listTools())) as McpServerError;
				t.ok(!noVpn.message.includes("VPN"), noVpn.message);
				fake.down = false;
				const rpc = (await rejects(t, new McpConnection(server(), fake.fetch).callTool("nope", {}))) as McpServerError;
				t.strictEqual(rpc.state, "error");
				t.ok(rpc.message.includes("unknown tool nope"), rpc.message);
			},
		},
		{
			name: "a handshake that stalls after initialize times out as unreachable, and the next call connects again",
			async run() {
				const fake = new FakeServer();
				fake.stallInitialized = true;
				const client = new McpConnection(server(), fake.fetch, 50);
				const stalled = (await rejects(t, client.listTools())) as McpServerError;
				t.strictEqual(stalled.state, "unreachable");
				t.ok(stalled.message.includes("no answer within") && stalled.message.includes("VPN"), stalled.message);
				fake.stallInitialized = false;
				t.strictEqual((await client.listTools()).tools.length, 3);
				t.strictEqual(fake.sessions, 2);
			},
		},
		{
			name: "the extension is built from the cache, refreshed from the server, and reports statuses",
			async run() {
				const fake = new FakeServer();
				const installed: string[][] = [];
				const reports: McpStatus[][] = [];
				const host = new McpHost((extension) => installed.push((extension.tools ?? []).map((tool) => tool.name)), (s) => reports.push(s), fake.fetch);
				host.setServers([{ ...server(), tools: [tools[0]!] }, server({ id: "off", enabled: false, tools })]);
				t.deepEqual(installed.at(-1), ["mcp__ha__get_state", "tool_search"]);
				const statuses = await host.refresh();
				t.deepEqual(statuses.map((s) => [s.id, s.state, s.tools?.length]), [["ha", "ok", 3]]);
				t.deepEqual(installed.at(-1), ["mcp__ha__get_state", "mcp__ha__turn_on", "mcp__ha__send", "tool_search"]);
				t.deepEqual(host.defaultPolicies(), { mcp__ha__get_state: "auto", mcp__ha__turn_on: "ask", mcp__ha__send: "ask" });
				const registered = new Map((host.extension.tools ?? []).map((tool) => [tool.name, tool]));
				t.strictEqual(registered.get("mcp__ha__get_state")!.replay, "safe");
				// Offered only once tool_search loads them.
				t.ok(["mcp__ha__get_state", "mcp__ha__turn_on", "mcp__ha__send"].every((name) => registered.get(name)!.deferred === true));
				t.strictEqual(registered.get("tool_search")!.deferred, undefined);
				t.strictEqual(registered.get("mcp__ha__get_state")!.description, "Get state\nRead an entity's state\n(MCP: Home Assistant)");
				t.strictEqual(registered.get("mcp__ha__turn_on")!.replay, "safe"); // idempotent
				t.strictEqual(registered.get("mcp__ha__send")!.replay, "unsafe");
				// A schema Pi cannot compile (a $ref to nothing) becomes any object, so the tool still works.
				t.deepEqual(registered.get("mcp__ha__send")!.parameters, { type: "object", additionalProperties: true });
				const done = await registered.get("mcp__ha__get_state")!.execute({ entity: "sun.sun" }, noApi, context);
				t.deepEqual(done.output, [{ type: "text", text: 'on: {"entity":"sun.sun"}' }]);
				const failed = (await rejects(t, registered.get("mcp__ha__send")!.execute({}, noApi, context))) as Error;
				t.strictEqual(failed.message, "rate limited");
				fake.down = true;
				await rejects(t, registered.get("mcp__ha__get_state")!.execute({ entity: "sun.sun" }, noApi, context));
				t.strictEqual(reports.at(-1)!.find((s) => s.id === "ha")!.state, "unreachable");
				const section = await host.extension.sections![0]!.render({} as never, context);
				t.ok(section!.includes("Use entity IDs.") && section!.includes("mcp__ha__") && section!.includes("tool_search"), section);
				t.ok(section!.includes("get_state, turn_on, send"), section);
			},
		},
		{
			name: "a refresh that answers after its server was edited is dropped",
			async run() {
				const fake = new FakeServer();
				let release = () => {};
				const gate = new Promise<void>((resolve) => (release = resolve));
				const reports: McpStatus[][] = [];
				const installed: string[][] = [];
				const host = new McpHost((extension) => installed.push((extension.tools ?? []).map((tool) => tool.name)), (s) => reports.push(s), async (url, init) => {
					await gate;
					return fake.fetch(url, init);
				});
				host.setServers([server()]);
				const pending = host.refresh();
				host.setServers([server({ url: "http://100.64.0.3/mcp" })]);
				release();
				await pending;
				t.deepEqual(reports.flat().filter((s) => s.id === "ha"), []);
				t.deepEqual(installed.at(-1), []);
			},
		},
		{
			name: "results become text and images; other content is described; output is cut",
			async run() {
				t.deepEqual(
					outputOf({
						content: [
							{ type: "text", text: "a" },
							{ type: "image", data: "AAAA", mimeType: "image/png" },
							{ type: "resource_link", uri: "file:///x", name: "x" },
							{ type: "resource", resource: { uri: "mem://y", text: "y" } },
						],
					}),
					[
						{ type: "text", text: "a\nx: file:///x\ny" },
						{ type: "image", data: "AAAA", mimeType: "image/png" },
					],
				);
				t.deepEqual(outputOf({ content: [], structuredContent: { n: 1 } }), [{ type: "text", text: '{\n  "n": 1\n}' }]);
				t.deepEqual(outputOf({ content: [] }), [{ type: "text", text: "(no output)" }]);
				const long = outputOf({ content: [{ type: "text", text: "x".repeat(30_000) }] })[0] as { text: string };
				t.ok(long.text.length < 24_100 && long.text.endsWith("characters]"), String(long.text.length));
			},
		},
		{
			name: "pi-mcp's OAuth shims: SHA-256 and the Buffer encodings",
			async run() {
				const hex = (text: string) => Buffer.from(sha256(new TextEncoder().encode(text))).toString("hex");
				t.strictEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
				t.strictEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
				t.strictEqual(
					hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
					"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
				);
				t.strictEqual(hex("a".repeat(1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3");
				t.strictEqual(Buffer.from("client:sécret").toString("base64"), "Y2xpZW50OnPDqWNyZXQ=");
				t.strictEqual(Buffer.from(new Uint8Array([251, 255, 191])).toString("base64url"), "-_-_");
				t.strictEqual(Buffer.from(new Uint8Array([0, 15, 255])).toString("hex"), "000fff");
				// RFC 7636, appendix B.
				const challenge = Buffer.from(sha256(new TextEncoder().encode("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))).toString("base64url");
				t.strictEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
			},
		},
		{
			name: "OAuth: signed out fails without a request; sign-in registers, checks state and PKCE; refresh; sign-out",
			async run() {
				const fake = new FakeOAuth();
				const store = memoryStore();
				const statuses: McpStatus[][] = [];
				const host = new McpHost(undefined, (s) => statuses.push(s), fake.fetch, () => store);
				host.setServers([server({ id: "gh", name: "GitHub", url: OAUTH_MCP_URL, authHeader: undefined, oauth: true, needsVpn: false })]);

				let status: McpStatus | null | undefined = (await host.refresh())[0];
				t.strictEqual(status?.state, "unauthorized");
				t.ok(status?.error?.includes("isn't signed in"), status?.error);
				t.deepEqual(fake.requests, []);

				// A sign-in whose answer carries another state is refused, and the code isn't spent.
				const first = new URL((await host.beginSignIn("gh")).url);
				t.strictEqual(first.origin + first.pathname, `${AUTH}/authorize`);
				t.strictEqual(first.searchParams.get("client_id"), "client-1");
				t.strictEqual(first.searchParams.get("redirect_uri"), OAUTH_REDIRECT_URL);
				t.strictEqual(first.searchParams.get("code_challenge_method"), "S256");
				t.strictEqual(first.searchParams.get("resource"), OAUTH_MCP_URL);
				fake.challenge = first.searchParams.get("code_challenge") ?? undefined;
				const forged = await rejects(t, host.finishSignIn("gh", `${OAUTH_REDIRECT_URL}?code=the-code&state=forged`));
				t.ok(String(forged).includes("doesn't match"), String(forged));
				t.strictEqual(fake.issued, 0);
				const denied = await rejects(t, host.finishSignIn("gh", `${OAUTH_REDIRECT_URL}?error=access_denied&error_description=The+user+said+no`));
				t.ok(String(denied).includes("The user said no"), String(denied));

				const begun = await host.beginSignIn("gh");
				t.strictEqual(begun.callbackScheme, "dev.jcdiv47.pidurable");
				const page = new URL(begun.url);
				// Registered once; each sign-in gets a new state and verifier.
				t.strictEqual(fake.registrations, 1);
				t.ok(page.searchParams.get("state") !== first.searchParams.get("state"));
				t.ok(page.searchParams.get("code_challenge") !== fake.challenge);
				fake.challenge = page.searchParams.get("code_challenge") ?? undefined;
				status = await host.finishSignIn("gh", `${OAUTH_REDIRECT_URL}?code=the-code&state=${page.searchParams.get("state")}`);
				t.ok(status?.state === "ok", status?.error);
				t.deepEqual(status?.tools?.map((tool) => tool.name), ["get_state", "turn.on", "send"]);
				t.strictEqual(fake.mcp.received[0]!.headers.authorization, "Bearer at1");
				t.strictEqual(store.state?.tokens?.refresh_token, "rt1");
				t.strictEqual(store.state?.oauthState, undefined);
				t.strictEqual(store.state?.codeVerifier, undefined);

				// The access token expires: the next session refreshes it once and goes on.
				fake.valid.clear();
				host.setServers([server({ id: "gh", name: "GitHub", url: OAUTH_MCP_URL, authHeader: undefined, oauth: true, needsVpn: false, enabled: false })]);
				host.setServers([server({ id: "gh", name: "GitHub", url: OAUTH_MCP_URL, authHeader: undefined, oauth: true, needsVpn: false })]);
				status = (await host.refresh())[0];
				t.ok(status?.state === "ok", status?.error);
				t.strictEqual(store.state?.tokens?.access_token, "at2");
				t.strictEqual(fake.mcp.received.at(-1)!.headers.authorization, "Bearer at2");

				// A refresh token the server no longer takes: the user has to sign in again.
				fake.valid.clear();
				fake.refreshToken = "revoked";
				host.setServers([server({ id: "gh", name: "GitHub", url: OAUTH_MCP_URL, authHeader: undefined, oauth: true, needsVpn: false, enabled: false })]);
				host.setServers([server({ id: "gh", name: "GitHub", url: OAUTH_MCP_URL, authHeader: undefined, oauth: true, needsVpn: false })]);
				status = (await host.refresh())[0];
				t.strictEqual(status?.state, "unauthorized");
				t.ok(status?.error?.includes("Sign in"), status?.error);

				await host.signOut("gh");
				t.strictEqual(store.state, undefined);
				t.ok(statuses.length > 0);
			},
		},
	];
}
