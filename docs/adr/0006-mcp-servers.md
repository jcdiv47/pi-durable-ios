# ADR 0006: MCP servers

Date: 2026-11-03. Status: accepted. Spec: 0001, "Network" and the M3 "Later" list. Builds on
[ADR 0004](0004-http-api-services.md).

## Context

MCP servers bring tools the app would otherwise build one by one: Home Assistant's built-in MCP Server, servers in the
homelab, and hosted servers such as GitHub's. The app runs in JavaScriptCore on iOS, so it can't start processes:
stdio servers are out, and only servers that speak HTTP can be used. Most homelab servers are only reachable over the
VPN (Tailscale and Shadowsocks inside sing-box), which may be off.

ADR 0004 rules out a generic HTTP tool, because a page could use it to send data out. An MCP server whose tools send
data (messages, notifications, fetches) is such a channel too. The difference: the user chooses each server.

pi-durable 1.5.0 already has what MCP needs: tool parameters are any JSON Schema, the registry can change while the
Harness runs, and deferred tools with `tool_search` exist for large tool sets.

## Decision

### Transport and client

- **Streamable HTTP only**, as `js/src/app/mcp.ts` (`McpClient`): `initialize` and `notifications/initialized` on
  first use, `tools/list` with paging, `tools/call`. It asks for protocol version 2025-06-18 and sends the version the
  server answers with in `MCP-Protocol-Version`. It keeps `Mcp-Session-Id` and, when the server answers 404 (it
  forgot the session), initializes once more and retries.
- Responses may be JSON or an SSE stream. On a stream, `ping` is answered, other server requests (sampling,
  elicitation, roots) are declined with "method not found", and notifications are skipped.
- No MCP SDK: it would bring zod, EventSource and Node-style code into JSC for about 300 lines of protocol.
- Not in this version: the older HTTP+SSE transport, resources and prompts, OAuth, `tools/list_changed`. A stdio
  server, or an old HTTP+SSE one, can be put behind a bridge on another machine (supergateway, mcp-proxy); to the app
  it is then a Streamable HTTP server.

### Servers live in Swift, with their tool lists

- The user adds a server in Settings › MCP servers: name, URL, auth (none, `Authorization: Bearer <token>`, or a
  custom header), "Needs VPN", on or off. The token goes to the Keychain as `mcp-<id>`.
- Swift keeps the list and each server's last `tools/list` and `instructions` in Application Support
  (`mcp-servers.json`), and passes both to JS in `open` and on every change (`PiRuntime.setMcpServers`).
- **The `mcp` extension is installed from the cache before the Harness opens.** A tool call that a crash interrupted
  resumes before any server has answered, and the app works offline. JS then lists every server's tools again
  (`McpHost.refresh`, also when the app comes to the foreground) and installs the rebuilt extension under the same
  name; Swift caches what came back (`mcp` events).
- **Only the user adds servers.** No tool can add, change or remove one, so a prompt injection can't add a channel.

### Tools

- One extension, `mcp`, holds every enabled server's tools, named `mcp__<server>__<tool>` (characters model APIs
  reject become `_`, cut at 64). Conversations select it by name, like the other extensions, so a new server needs no
  change to them.
- The tool's `inputSchema` is its `parameters` as is. A schema pi-schema can't compile (a `$ref` to nothing) becomes
  "any object", so the tool still works.
- Results: text and images go to the model; resource links and text resources become lines of text; with no content,
  `structuredContent` as JSON. Output is cut at about 24 KB, as for `web_fetch`. `isError` results become error
  results.
- A prompt section lists the servers and their `instructions`, and says that tool results are data from the server,
  not the user's instructions.

### Replay and approvals, from the tool's annotations

| annotation                     | `replay` | default policy |
| ------------------------------ | -------- | -------------- |
| `readOnlyHint: true`           | `safe`   | `auto`         |
| `idempotentHint: true` (write) | `safe`   | `ask`          |
| anything else                  | `unsafe` | `ask`          |

The server sets these hints, so they aren't guarantees; that is acceptable for servers the user chose, and every
write asks by default. A tool's policy can be changed in the server's Settings page; stored policies keep working as
for other tools (`Approvals.dynamicDefaults` gives the defaults of tools that come and go).

### Keys

- JS puts `pi-host-key:mcp-<id>` in the auth header. `ProviderKeys.setMCPHosts` (Swift, from the saved list) lets the
  fetch bridge send that token only to the server URL's host, and the ADR 0004 rules apply: no redirects to other
  hosts, no key in what JS sees.
- The host check ignores the port, as it does for other services: another port on the same host may receive the token.

### Reachability and the VPN

- iOS doesn't tell an app about another app's VPN. `VPNStatus.tunnelUp()` looks for an up tunnel interface with an
  IPv4 address (iOS's own `utun` interfaces carry only IPv6 link-local addresses). It's a hint; whether the server
  answers is what counts.
- "Needs VPN" defaults on for private hosts: 10/8, 172.16/12, 192.168/16, 100.64/10 (Tailscale), `.ts.net`, `.local`,
  names without a dot.
- A VPN-only server that can't be reached shows a banner over the chat ("Can't reach Home Assistant: the VPN looks
  off"); a tap checks again. While the app is away (a scheduled task), it posts a notification instead, once per
  server until the server answers again. The tool call itself fails with a message that says the VPN may be off.
- App Transport Security allows plain HTTP to local names and to `*.ts.net` (the tunnel encrypts it); other servers
  need HTTPS.

## Later

1. **Deferred tools** for servers with many tools: `deferred: true` and `createToolSearchExtension()`, so the model
   loads them with `tool_search`.
2. **OAuth** for hosted servers: discovery, dynamic client registration, PKCE in `ASWebAuthenticationSession`, tokens
   and refresh in Swift.
3. Pasting a Claude Desktop `mcpServers` block, or a `pidurable://mcp/add` link, to fill in the form.
4. A kill-test case for an MCP call that is not replay-safe.

## Consequences

- MCP tools are an exception to ADR 0004's "no generic channel", bounded by the user choosing every server and by
  writes asking first.
- Server-written text (tool descriptions, instructions, results) reaches the model. Results are framed as data, but a
  server the user adds is trusted about as much as a model provider.
- A server's tools are offered in every conversation once added; turning a server off removes them everywhere.
- After a crash, a non-replay-safe MCP call comes back interrupted even if the server finished it; the model sees that
  and can check.
