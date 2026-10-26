# M0: runtime viability (JavaScriptCore)

Date: 2026-10-26. pi-durable / pi-ai / chord **1.4.0**, esbuild 0.28.2, bun 1.4.3.
Targets: iPhone 17 Pro simulator (iOS 26.5) and an iPhone Air running iOS 27.2 (no JIT for
third-party JSContexts). Streaming provider: **DeepSeek `deepseek-flash`** (at the owner's
request, in place of Anthropic; the Anthropic provider is bundled and wired the same way).

**Verdict: JSC is workable. No WKWebView fallback is needed, so no ADR.**

## Acceptance status

| M0 item | Simulator | iPhone | How |
|---|---|---|---|
| 1. XcodeGen app + widget, App Group, signing, capability check | pass | pass | `scripts/m0-check.sh capabilities`; [m0-capabilities.md](m0-capabilities.md) |
| 2. Bundle in JSContext, polyfills, one streamed response in a bare SwiftUI view | pass | pass | `scripts/m0-check.sh stream`; [screenshot](img/m0-stream-simulator.png) |
| 3. Swift `SqliteDatabase` facade, `SqliteStorage.open`, storage conformance **inside JSC** | pass, 25/25 | pass, 25/25 | `scripts/m0-check.sh conformance`; also `swift test` (macOS JSC) |
| 4. Scripted kill test | pass | pass | `scripts/kill-test.sh` |
| 5. Measurements | done | done | `scripts/m0-check.sh measure`; below |

Beyond the spec, the conformance run also includes our 11-case facade contract and 10 polyfill
cases. All 46 pass in every environment: macOS JSC, simulator with JIT, simulator with
`JSC_useJIT=false`, and the iPhone.

## Bundling

- esbuild IIFE, `platform: "browser"`, `target: "safari26"`, minified, `keepNames`.
  `platform: "browser"` is required: the Anthropic SDK's `browser` field swaps its Node internals
  for fetch-only ones, and with `neutral` it pulls in `node:fs` and others.
- `pi-runtime.js`: **1,234,623 bytes** minified (344 KB gzip). Biggest inputs: `openai` SDK 292 KB
  (needed by pi-ai's chat-completions API, which DeepSeek uses; adding DeepSeek grew the bundle
  from 879 KB), TypeBox 209 KB, `@anthropic-ai/sdk` 190 KB, pi-durable 174 KB, pi-ai 128 KB,
  web-streams-polyfill 64 KB, chord 54 KB, core-js URL 51 KB. Per-file breakdown:
  `js/dist/*.meta.json`.
- Not imported, per the spec: `/env/node`, `/storage/*/node`, `/images/node`, Photon.

## Globals: what plain JSContext lacks, and what we did

JSC already has `Intl` (including `Segmenter`), `Promise.withResolvers`, `Error.captureStackTrace`,
`WeakRef`, `FinalizationRegistry`, `Array.fromAsync`, `BigInt` and `globalThis`.

Polyfilled in `js/src/host/` (natives in `JSRuntime.swift`):

| Global | Implementation |
|---|---|
| `console` | → `os.Logger` (subsystem `dev.pi.durable`, category `js`) |
| `setTimeout`/`setInterval`/clear* | `DispatchWorkItem` on the JS queue. Handles have Node-style `ref`/`unref` and `Symbol.toPrimitive` (a bundled dependency calls `.unref()` when present) |
| `queueMicrotask` | `Promise.resolve().then` |
| `performance.now` | `ContinuousClock` |
| `crypto.getRandomValues`, `randomUUID` | `SecRandomCopyBytes` |
| `TextEncoder`/`TextDecoder` (+ streams) | UTF-8 only, via native encode/decode; streaming keeps split sequences; BOM; `fatal` |
| `ReadableStream` and friends | `web-streams-polyfill` 4.3.0 |
| `URL`, `URLSearchParams` | `core-js-pure` 3.51.0 |
| `AbortController`/`AbortSignal` (`timeout`, `any`), `Event`, `EventTarget`, `CustomEvent`, `DOMException` | ours |
| `structuredClone` | ours: cycles, Date, RegExp, Map, Set, typed arrays, Error; `DataCloneError` on functions |
| `atob`/`btoa` | ours |
| `fetch`, `Headers`, `Request`, `Response`, `Blob`, `File`, `FormData` | `URLSession` data delegate → `ReadableStream`; abort cancels the task. `FormData` must exist (an unguarded `instanceof FormData`) |

Referenced by the bundle but deliberately **not** provided: `process`, `Buffer`, `navigator` (all
behind `typeof` guards), `crypto.subtle` (only the OpenAI SDK's webhook verifier, which we don't
call), and `WebSocket` (names and comments only).

Gaps that matter:

- **Unhandled promise rejections are silent.** The JSC callback for them
  (`JSGlobalContextSetUnhandledRejectionCallback`) is private API. Pi reports its own background
  failures through `onReport`, which we log, but a stray rejection in our own JS disappears.
  Keep `await`s inside try/catch in host code.
- `JSContext.isInspectable = true` in all builds, so Safari's Web Inspector attaches to the
  runtime. Useful; turn it off in Release later if wanted.

## SQLite facade

- Swift `SQLiteConnection` over the system sqlite3 runs **synchronously on the JS queue** (like
  `node:sqlite`). A JS `IOSSqliteDatabase` provides chord's promise contract: a serial operation
  queue, `BEGIN IMMEDIATE`/`COMMIT`/`ROLLBACK`, transaction handles that expire, `AggregateError`
  when a rollback fails, idempotent `close`. It mirrors chord's `NodeSqliteDatabase`.
- WAL, `synchronous = NORMAL`, `busy_timeout = 5000`, `wal_autocheckpoint = 1000`; close runs
  `wal_checkpoint(TRUNCATE)`. Prepared statements are cached.
- Bindings: integers within ±2^53 bind as int64, BigInt as int64 (range-checked); reads beyond
  the safe range come back as BigInt. Text binds with an explicit byte length: `-1` truncated
  strings at NUL, which our facade cases caught.
- **Pi's conformance suite does not exercise facade rollback.** Swapping `ROLLBACK` for `COMMIT`
  still passed all 25 cases. Our facade cases (`js/test/facade-cases.ts`) catch it. Worth
  upstreaming.
- Storage conformance takes 130–170 ms for 25 cases (simulator, JIT on/off) and 142 ms on the
  iPhone. Storage is not a bottleneck.

## Kill test

`scripts/kill-test.sh`, with fixtures in `js/src/killtest.ts`:

1. `-PiMode killtest-start` opens `<App Group>/pi/killtest.sqlite` with the scripted model
   `faux/killtest`. It calls `slow_lookup` (`replay: "safe"`) and `send_message` (no replay) in
   one round, with `toolExecution: "parallel"`, and both tools sleep 120 s.
2. The script waits for both tools' `start` markers, then kills the app (`simctl terminate`, or
   `devicectl … terminate --kill`, i.e. SIGKILL) and confirms neither tool finished.
3. `-PiMode killtest-resume`: `Harness.open` + `resume()` restart the turn. Re-submitting the same
   `requestId` finds the original submission instead of starting another.
4. It checks that the turn is done; `slow_lookup` started exactly once in the new process and
   returned ok; `send_message` did not rerun and its result is the harness's "was interrupted and
   may have partially run" error; and the model's final answer saw both outcomes
   (`Done: slow_lookup=ok, send_message=error`). Transcript: user, system, assistant (2 calls),
   2 tool results, assistant.

It passes on the simulator (JIT on and off) and on the iPhone. The kill lands **mid-tool**. A kill
**mid-model-stream** isn't scripted yet (see recommendations).

The in-process variant, `HarnessTests.crashAndResume` (`JSRuntime.terminate()`, then a fresh
runtime on the same file), runs in `swift test`.

## Measurements

Prompt: about 300 words of prose from `deepseek/deepseek-flash` (no reasoning content came back).
Each launch is a new process. "Cold start" is kernel process start → `Harness.open` resolved,
read with `sysctl(KERN_PROC)` (so it includes dyld and app launch). Memory is `phys_footprint`.
Time per token is split two ways: **network** (first to last response-body chunk ÷ output tokens)
and **JS CPU** (time the JS queue spent running JS during the run ÷ output tokens).

| | iPhone Air, Debug (n=3) | iPhone Air, Release (n=3) | Sim, JIT on (n=2) | Sim, `JSC_useJIT=false` (n=2) |
|---|---|---|---|---|
| Cold start → `Harness.open` | 111–113 ms (172 first launch after install) | 109–113 ms (139 first) | 605–640 ms¹ | 601–604 ms¹ |
| …of which bundle evaluate | 35–49 ms | 37–40 ms | 31 ms | 32 ms |
| …of which `open` (storage + harness + root) | 12–14 ms | 12–14 ms | 12 ms | 13 ms |
| Footprint before JS | 9.4 MB | 9.4 MB | 27 MB¹ | 27 MB¹ |
| Footprint idle (after open + 3 s) | **27.3–27.8 MB** | 27.4–28.0 MB | 42 MB | 37 MB |
| Peak footprint during a run | **33.6–34.0 MB** | 33.6–34.3 MB | 67–69 MB | 45 MB |
| First delta (TTFT, incl. network) | 0.73–1.0 s | 1.05–1.2 s | 0.76–1.3 s | 0.93–1.1 s |
| Network ms/token | 8.4–9.8 | 9.9–10.1 | 9.0–10.3 | 8.4–9.6 |
| **JS CPU ms/token** | **0.38–0.55** | 0.42–0.62 | 0.28–0.29 | 0.32 |
| JS busy share of the run | 4–6 % | 4–6 % | 3 % | 3–4 % |
| CPU loop benchmark (3M iterations + 20k-row JSON) | 123–125 ms | 123–128 ms | 15 ms | 75–99 ms |

¹ Simulator Debug launch overhead (debug dylibs) and macOS-hosted memory accounting. Use the
device numbers.

Takeaways:

- **No JIT is fine for this workload.** Without the JIT, pure JS is about 8× slower than with it
  (loop benchmark). But an agent turn spends about 95 % of its time waiting on the network: JS
  costs about 0.5 ms per token against about 9 ms per token of streaming. Bundle evaluation is
  about 40 ms.
- **Memory is small:** about 28 MB idle and about 34 MB peak for the whole app on device. The JIT
  costs memory: the simulator with the JIT peaks 20+ MB higher than without.
- Debug and Release are indistinguishable. JSC is a system framework, and our Swift is a thin
  layer.
- **Streaming granularity is set by Pi, not the bridge.** Over a run, the fetch bridge delivers
  about 170–240 network chunks, but `watchEvents` emits about 22–30 `message_update`s, about one
  per 100 ms. Pi derives deltas from its throttled, durably committed partial. That's fine for
  UI; just don't expect per-token callbacks from `watchEvents`.

Raw reports: `scripts/.out/metrics-*.json` (git-ignored; regenerate with `scripts/m0-check.sh measure`).

## Problems hit along the way

- **Xcode 27 beta:** `xcodebuild test` of the PiRuntime package on an iOS simulator (a hostless
  logic test) fails with "The test runner hung before establishing connection", on two
  simulators. We worked around it by running the same suites in the app (`-PiMode conformance`),
  which also covers the device. `swift test` (macOS JSC) still runs everything. Separately, a test
  resource folder named `Resources` breaks iOS codesigning of the resource bundle, so it's `JS/`.
- `devicectl device process launch` parses some app arguments as its own short flags
  (`-PiPrompt` → `-t`), and passes `--` through to the app, where `UserDefaults` then pairs it
  with the next argument. Scripts pass free text through the environment instead.
- `simctl launch` and `devicectl` return before the app has deleted its previous report. Scripts
  stamp each launch with `-PiRunId`, and the app writes that ID into every report.
- An argument-order bug in our `settle()` (`requestId` and `text` swapped) looked like a requestId
  dedup failure in the facade. Pi's dedup is correct with our facade.

## Recommended spec changes

1. M0 item 2: say "one streamed response from an API-key provider" rather than Anthropic. The
   provider is a setting; the key path (Keychain → Swift-side substitution for an allowlisted
   host) is the same for every provider. DeepSeek was used here. `ProviderKeys.allowedHosts`
   lists anthropic, deepseek, openai and openrouter.
2. Signing: the free Personal Team provisions every M0 capability (see m0-capabilities.md). The
   spec's "switch to a paid account if anything is missing" isn't triggered. The real limits are
   the 7-day profile expiry and the lack of APNs, so plan the paid account around M3 (unattended
   runs, push) rather than M0.
3. Note that test devices may run a newer major iOS (this phone runs 27.2) than the simulator
   runtime (26.5). Keep the deployment target at 26.0, and run kill tests on both.
4. Testing: run the storage conformance suite **in the app** (`-PiMode conformance`) rather than
   as an XCTest logic test. That is the only way it runs in the no-JIT environment that ships.
   Also make the facade contract cases part of the required suite, since Pi's suite misses
   rollback.
5. Kill tests (Testing section): add a **mid-model-stream** kill (faux provider with
   `tokensPerSecond`), plus a kill with a real provider, before M1 ships. Today the kill lands
   mid-tool only.
6. Performance risk ("without JIT"): downgrade it. Measured JS CPU is about 0.5 ms/token and
   about 5 % of a run on device. Keep `scripts/m0-check.sh measure` as a regression check when
   compaction and TypeBox-heavy features land.
7. Bundle: expect about 1.2 MB with two provider families. Each OpenAI-compatible provider shares
   the `openai` SDK; adding more of them costs little.
