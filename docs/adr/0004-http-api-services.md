# ADR 0004: HTTP API services, starting with web search

Date: 2026-10-30. Status: accepted. Spec: 0001, "Network" and the Keychain line of the architecture sketch; the
M3 "Later" list.

## Context

Today the app calls the network only for model providers. JS `fetch` runs over URLSession (`FetchBridge`), and
Swift swaps a `pi-host-key:<provider>` header value for the Keychain key, but only on that provider's hosts
(`ProviderKeys.allowedHosts`).

We want tools that call other HTTP APIs: web search now (DeepSeek Search, Brave Web Search), maps next (AMap), and
more later. These APIs authenticate differently (a Bearer header, `X-Subscription-Token`, a `key` query parameter),
have different quotas, and return different shapes. Brave's free plan, the one in use, allows 1 request per second
and 2,000 per month. pi-ai 1.4.0 has no server-side search tools. Search inside the model (Anthropic's or OpenAI's
server tools, OpenRouter `:online`) would also skip durable tool tasks and native cards.

## Decision

### Services

A service is a keyed HTTP API. Model providers are services too, and `ProviderKeys.allowedHosts` becomes the one
table of them in Swift: id, hosts, and an optional monthly cap. Each service has one Keychain item, as today.
Settings lists the services that are not model providers in their own section, with key status and this month's
request count. A service may share a model provider's key: DeepSeek Search is `deepseek` on `api.deepseek.com`, so
it needs no new entry.

| id         | hosts                  | key sent as                          | limits                                  |
| ---------- | ---------------------- | ------------------------------------ | --------------------------------------- |
| `deepseek` | `api.deepseek.com`     | `Authorization: Bearer …`            | search 100/s, fetch 25/s (per account)  |
| `brave`    | `api.search.brave.com` | `X-Subscription-Token: …`            | 1/s, 2,000/month (free plan)            |
| `amap`     | `restapi.amap.com`     | `key=…` query parameter              | per key (later)                         |

### Keys in headers and in URLs

JS puts the placeholder wherever the API wants the key: a header value or a URL query value. `FetchBridge` replaces
it in both places, only for that service's hosts. Keys must never reach JS, so for any request that carried a key:

- the `response` event reports the URL as JS sent it, not `response.url`;
- a redirect is followed only to another host of the same service; for any other redirect, JS gets the redirect
  response itself (URLSession would copy the key's headers to the new request);
- diagnostics log only the URL as JS sent it.

### Rate limits and quotas

- **Monthly count, in Swift.** Swift counts keyed requests per service and calendar month (UserDefaults), at the
  point where it substitutes the key. When a service has a monthly cap and reaches it, the bridge refuses the request
  with an error the model can read ("Brave's monthly quota is used up"). If a response has `X-RateLimit-Remaining`,
  as Brave's do, that value corrects the count.
- **Spacing and retries, in JS.** `serviceFetch(service, url, init, signal)` (`js/src/app/services.ts`) queues each
  service's requests and spaces them by its minimum interval (Brave: 1.1 s). Without this, parallel tool calls run
  into 429s. After a 429 it retries once, honoring `Retry-After`. It turns HTTP errors into short messages the model
  can act on.

### Web tools

The `web` extension (`js/src/app/web.ts`):

- `web_search(query, count?, freshness?)`, `replay: "safe"`. It calls the provider chosen in Settings and returns
  `{ title, url, snippet, date?, site? }[]`.
  - **DeepSeek:** `POST /v1/tools/search`. The snippet is the result's `summary`, which DeepSeek writes for models.
    `freshness` becomes an `after:` operator in the query.
  - **Brave:** Web Search only (`GET /res/v1/web/search`, `extra_snippets=true`, at most 20 results). The snippet is
    `description` plus `extra_snippets`. `freshness` maps to `pd`, `pw`, `pm` or `py`. LLM Context is not used.
- `web_fetch(url)` reads a page as Markdown through DeepSeek Fetch (`POST /v1/tools/fetch`), so it needs a DeepSeek
  key. We write no HTML extraction of our own.
  - **Approval:** `web_fetch` is the channel a page could use to send data out (`evil.example/?d=…`). Its call runs
    without asking when the URL appeared in a search result or a user message in the conversation. Any other URL
    asks first. This is a per-call rule in the approval hook, beside the per-tool policy.
- **Output size:** search output is capped at about 8 KB and fetched pages at about 24 KB.
- **Stored policies:** Swift stores every tool's policy once one changes. New tools keep their default (`web_fetch`:
  ask) under a stored map.
- **Display:** `web_search` joins `cardTools`. The chat draws it as a "Sources" card: title, site, date, and a link
  you can tap.
- **System prompt:** a prompt section, present only when a search provider is set up, says when to search and to
  cite URLs.
- **Offline tests:** a `scripted` search provider returns fixed results, so conformance tests and scripts stay
  offline.

### Not done

- **A generic `http_request` tool.** It would be an exfiltration channel with no bounds. A new API becomes a service
  with its own tools instead.
- **Search inside the model.** See Context.

## Adding a service

1. A row in the Swift table: hosts and an optional monthly cap.
2. A Settings entry for its key.
3. A JS module whose tools call `serviceFetch`. It sets the minimum interval and where the placeholder goes.
4. Optionally a card in `cardTools`, and an approval policy in `defaultPolicies` for anything that writes.

For AMap:

- **Coordinates.** AMap expects GCJ-02 coordinates, but `location_current` returns WGS-84. The AMap tools convert
  them first, with `/v3/assistant/coordinate/convert` or a local transform.
- **MapKit.** In mainland China, MapKit's search and directions already run on AMap data and need no key. That is
  worth comparing before adding AMap tools for routing.

## Consequences

- Every outgoing key still goes through one Swift allowlist. URL query keys are new, and so are the rules that keep
  them out of JS.
- A quota is enforced on the device, so a runaway schedule can't spend Brave's month. The count is approximate:
  Brave does not bill failed requests, but we count them.
- `web_fetch` depends on DeepSeek. Someone with only a Brave key can search but not read pages.
- `web_search` replays after a crash, so one more request is billed or counted. A search is a read, so this is
  accepted.
