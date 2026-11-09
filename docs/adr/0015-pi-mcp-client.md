# ADR 0015: pi-mcp as the MCP client

Date: 2026-11-10. Status: accepted, built. Spec: 0001, "Network". Replaces the "Transport and client" part of
[ADR 0006](0006-mcp-servers.md); the rest of ADR 0006 stands.

## Context

ADR 0006 wrote our own Streamable HTTP client in `mcp.ts` (about 300 lines) because the official MCP SDK would bring
zod, EventSource and Node-style code into JavaScriptCore. Earendil now publishes `@earendil-works/pi-mcp`, a small
MCP client with no dependency on the official SDK, at the same version as the rest of Pi (1.5.0). Its core is plain
`fetch`, `ReadableStream` and `AbortController`, which the polyfills already provide. It covers more of the protocol
than our client did, and its maintainers follow the spec.

## Decision

- **`mcp.ts` uses pi-mcp's `McpClient` and `StreamableHttpTransport`.** `McpConnection` is one server's session over
  them: it connects on first use, shares the connection between concurrent calls, and runs a request once more in a new
  session when the server forgot the old one (`McpSessionExpiredError`, HTTP 404). It explains failures in the words
  Settings and the model saw before (`McpServerError`, with the `unreachable`, `unauthorized` or `error` state).
- The key placeholder goes in the transport's `headers`, so Swift's key substitution is unchanged. The fetch bridge is
  pi-mcp's `fetch` (the global one, or the tests' fake).
- **No server-to-client GET stream** (`openGetStream: false`): it would keep a connection per server open, and
  reconnect, for notifications the app ignores. Server requests that arrive on a request's own stream are answered
  as before: `ping`, and "method not found" for sampling, elicitation and roots.
- Timeouts: connecting and each `tools/list` page give up after 15 s (the client's `requestTimeoutMs`); `tools/call`
  has none (`timeoutMs: 0`). A tool call the user stops sends `notifications/cancelled`.
- Results go through pi-mcp's `toLlmContent`. `outputOf` joins its text, cuts it at about 24 KB and puts images after
  it, as before.
- **The bundle**: pi-mcp's index exports its stdio transport, which imports `node:child_process`. The app can't start
  processes, so `build.ts` resolves that module to a stub that throws. Its SSE reader calls Node's
  `Buffer.byteLength`. A global `Buffer` would send the OpenAI and Anthropic SDKs down their Node paths (they check
  `typeof Buffer`, then call `Buffer.from`), so `build.ts` gives that one module a local `Buffer` that only counts
  UTF-8 bytes. The plugin fails the build if pi-mcp stops using `Buffer.byteLength`, so the shim doesn't outlive its
  need.
- pi-mcp is pinned to the same exact version as pi-durable, pi-ai, pi-schema and chord.

## What changed for servers

- The client asks for protocol version 2025-11-25 and accepts 2025-06-18, 2025-03-26 and 2024-11-05. A server that
  answers with another version is refused; ours used whatever the server said.
- `initialize` must return `serverInfo.name` and `serverInfo.version`, and every listed tool must have an
  `inputSchema`, as the spec requires. Ours let both go.
- A response stream that drops before its answer is resumed with `Last-Event-ID` when the server numbers its events.
- A session that is replaced gets a best-effort `DELETE`.
- Results: a resource link is `name: uri` and an embedded text resource is its text, without our "Resource …" labels.
  An embedded image resource reaches the model as an image. With only `structuredContent`, the JSON is indented by two
  spaces.

## Consequences

- About 250 lines of protocol code are gone from `mcp.ts`, and fixes to the protocol come with Pi updates.
- OAuth (ADR 0006, "Later" item 2) can start from `@earendil-works/pi-mcp/oauth` rather than from nothing. The browser
  step and the token store stay in Swift.
- A server that breaks the spec in the ways listed above now fails to connect, and Settings shows the error.
- The build depends on two internal paths in pi-mcp (`dist/index.js` importing `./transports/stdio.js`, and
  `dist/transports/streamable-http.js`). A pi-mcp update that moves them fails the build or brings `node:*` imports
  back, which also fails the build. It can't break silently.
