# Spec 0001 — Pi Durable on iOS: an Apple-native durable agent

Triage: `ready-for-agent` (greenfield; start with Milestone 0)

## Problem Statement

Agent apps on iPhone are either thin chat clients for a server or chat boxes that
forget everything when iOS suspends them. Neither uses what makes the iPhone useful:
Calendar, Reminders, Health, Shortcuts/Siri, widgets, Live Activities, the Lock
Screen and notifications. And iOS suspends and kills background apps all the
time, so any long agent run on the device has to survive being killed.

`@earendil-works/pi-durable` (Earendil, shipped with Pi 1.0 on 2026-10-01) is an
agent harness where every model request, tool call, compaction and custom task
checkpoints to storage and resumes after a crash. That is exactly what an
agent running inside iOS's lifecycle needs.

## Solution

A personal, sideloaded, **iPhone-only** native SwiftUI app that runs the Pi Durable
harness **on the device**, inside an embedded JavaScriptCore runtime. LLM calls go
to API-key providers through pi-ai. Swift owns everything Apple-specific (UI,
widgets, App Intents, background execution, EventKit, HealthKit, Keychain, SQLite).
The TypeScript harness owns the agent loop, durable state, tools and documents.

The headline feature is **agent-generated native UI**. The agent designs widgets,
Lock Screen accessories, Live Activities, Siri/Spotlight snippets and chat cards
by composing a typed component vocabulary through tools. A prebuilt, shared
SwiftUI renderer draws them. How much the agent generates and how much is fixed is
an explicit, tunable setting (see "Generativity dial").

## Decisions already made

- Personal sideload only. No App Store. Guideline 2.5.2 does not apply, but iOS
  still cannot compile or load Swift at runtime, so generated UI is **interpreted
  data**, never code.
- iPhone only. Apple Watch is a later milestone. iPad, Mac and visionOS are out of scope.
- Agent runtime: Pi Durable + pi-ai, **API-key providers** (Anthropic, OpenAI,
  OpenRouter, any OpenAI-compatible base URL). No OAuth/subscription login.
- Apple Notes is deferred (it has no public API; a later workaround goes through Shortcuts).
- Wrap Apple components as a typed layer exposed to the agent through tools,
  with an escape hatch to primitives. The generative/deterministic balance is a
  setting we expect to tune, not a fixed decision.

## Non-goals (v1)

- App Store distribution, multiple users, accounts, a server backend.
- iCloud/CloudKit sync of agent state (Pi Durable expects one process to own its storage).
- On-device LLMs (Apple Foundation Models, MLX). A Foundation Models pi-ai provider
  for cheap jobs (titles, routing) is a later idea, not v1.
- Bash/shell tools or `pi-coding-agent` coding workflows.
- Apple Notes, Mail, Messages automation.

## Environment and versions

- Dev machine: Apple Silicon Mac, Xcode 27, iOS 26.5 simulator runtime installed.
- Deployment target: **iOS 26.0**, needed for `BGContinuedProcessingTask`,
  Liquid Glass, App Intents interactive snippets and the current WidgetKit features.
- Project generation: **XcodeGen** (`project.yml` checked in; the `.xcodeproj` is generated
  and git-ignored) so agents can edit the project configuration as text.
- JS toolchain: Bun or Node + esbuild. Pin `@earendil-works/pi-durable`,
  `@earendil-works/pi-ai` and `@earendil-works/chord` to the **same exact version**
  (1.4.0 at time of writing). Pi Durable is marked experimental; upgrade on purpose.
- Signing: personal team. **Milestone 0 must check** that the capabilities we need
  work under the chosen signing: App Groups, HealthKit, widget extension, background
  modes, Live Activities, Keychain sharing. Free Apple ID builds expire after 7 days
  and may lack some capabilities. If anything is missing, switch to a paid developer account.

## Architecture

```
PiApp (the only process that runs the agent)
 ├─ SwiftUI shell: conversations, run view, approvals, component gallery, settings
 ├─ PiRuntime (Swift): hosts a JSContext on a dedicated thread/actor
 │   ├─ pi-runtime.js  (esbuild IIFE bundle: pi-durable + pi-ai + chord + our extensions)
 │   ├─ host polyfills: fetch (streaming body) over URLSession, AbortController,
 │   │   TextEncoder/TextDecoder, crypto.getRandomValues/randomUUID, setTimeout/
 │   │   clearTimeout, queueMicrotask, structuredClone, URL/URLSearchParams, console
 │   ├─ SqliteDatabase facade → Swift sqlite3 (async, serialized, transactional)
 │   ├─ IOSExecutionEnv → sandboxed workspace folder in the app container (FileSystem only;
 │   │   Shell returns `shell_unavailable`)
 │   └─ Swift tool bridge: JS tool stubs → typed Swift handlers (EventKit, HealthKit, …)
 ├─ Keychain: provider API keys, injected per request on the Swift side of fetch
 └─ App Group container
      ├─ pi/session.sqlite         (Pi Durable storage; owned by PiApp only)
      ├─ surfaces/<id>.json        (published component specs, read-only for extensions)
      └─ snapshots/<id>.json       (data values the agent already produced, e.g. $doc.* values)

PiWidgets (WidgetKit extension): renders surfaces with PiUI; resolves native data
  sources itself (Health, Calendar) on its timeline; never opens Pi storage, never loads JS.
PiUI (Swift package): component schema types, validator, renderer. Shared by app, widgets,
  Live Activities, App Intent snippets, and the Watch later.
```

### Runtime host: JavaScriptCore

- Use `JSContext` from JavaScriptCore, not a hidden `WKWebView` or nodejs-mobile.
  Reasons: it ships with the OS, calls into Swift synchronously, has no web-view
  lifecycle, and is small. It runs without JIT in a third-party process, which is
  acceptable because the agent mostly waits on the network. Measure it anyway in M0.
- Bundle with esbuild to a single IIFE (or ESM evaluated with `evaluateScript`).
  Tree-shake; the package root pulls in TypeBox (~4 MB RSS when bundled, per the README).
- **Do not import** `/env/node`, `/storage/*/node`, `/images/node` or Photon (WASM).
  Images: send them as-is (no image processor), or later add a Swift image tool that
  resizes with ImageIO and returns PNG/JPEG.
- The portable SQLite core (`@earendil-works/pi-durable/storage/sqlite`,
  `SqliteStorage.open(db, { prefix: "pi_" })`) uses no Node APIs. We implement chord's
  `SqliteDatabase` facade (`exec`, `run`, `get`, `all`, `transaction`, `close`; all
  promise-based, positional bindings, unrelated operations queued during a
  transaction, rollback on callback rejection) over sqlite3 in Swift. WAL mode,
  `synchronous = NORMAL`. **It must pass `registerStorageConformance` running inside
  JSC** (for example through a small test runner bundled into a test build).
- `IOSExecutionEnv` implements `ExecutionEnv` (FileSystem + Shell) over a per-
  conversation workspace folder. It must pass `registerEnvConformance` for the
  FileSystem parts. `exec` returns `shell_unavailable`.
- Network: the JS `fetch` polyfill hands requests to Swift `URLSession` and streams
  response bytes back as a `ReadableStream` (pi-ai needs this for streamed responses).
  It supports `AbortSignal`. Provider keys are added on the Swift side based on the
  host, so they never sit in JS heap or Pi storage.

### Process ownership

Pi Durable has no cross-process locking: **one process owns the storage**.

- Only PiApp opens `session.sqlite`. App Intents are declared in the app target so
  they run in the app process (launched in the background when needed) and talk to
  the harness directly.
- Widget and Live Activity extensions only read `surfaces/` and `snapshots/` JSON
  that PiApp exports after the relevant commits.
- Interactive widget buttons and Control Center controls run App Intents in the app process.

### Durability on iOS

| Pi Durable concept | iOS mapping |
|---|---|
| `Harness.open` + `harness.resume()` | On every launch: cold start, background launch by an intent, background task, or notification action |
| `onWake(wake)` / `harness.wake()` (the evicted-host pattern from the README's Durable Object example) | `wake.active` → request `BGContinuedProcessingTask` (user-started runs) or keep a foreground run going; `wake.at` → schedule `BGAppRefreshTask` and, for reminder-style tasks the user can see, a local notification at `at`. iOS timing is best effort: tasks wake **at or after** `at`. |
| `runtime.sleepUntil` in custom tasks | Briefings, reminders, scheduled widget refreshes |
| Tool `replay: "safe"` | Read-only Apple queries; idempotent writes |
| No `replay` (interrupted → model told) | Non-idempotent side effects |
| `requestId` exactly-once | Every entry point: Siri/Shortcuts intents, widget buttons, notification actions, share sheet. Derive the id from the intent invocation and payload. |
| `settings.restartLimit` / parked tasks | Show parked tasks in the UI with Retry (`harness.retryTask`) |
| `onReport` | A persistent diagnostics log in the app, plus OSLog |
| Hooks + `api.memo` | Approval gates for sensitive tools; the decision survives restarts |

Lifecycle rules:
- Arm wake-ups **before** any call that can start work (submit, compact, abort,
  registry change), as in the README's Durable Object example.
- On `scenePhase == .background` with active work, request background continuation.
  If iOS still suspends the app, accept it: Pi resends cut-off model requests and
  replays safe tools on the next resume.
- Never assume a timer fired; always call `resume()` on launch.

## Agent design

- One root conversation per user thread; forks for design variants.
- Extensions (`defineExtension`), each with its system prompt section and tools:
  - `apple.calendar` — EventKit events + reminders
  - `apple.health` — HealthKit read queries
  - `apple.context` — date/time/timezone, location (on request), device state
  - `apple.notify` — local notifications, including actionable approvals
  - `ui.surfaces` — the component tools (below)
  - `memory` — a user profile/preferences document
- Approval policy: a `beforeTool` hook gates writes (create/modify event, publish
  surface to the Home Screen) according to per-tool settings: `auto`, `ask`, `deny`.
  `ask` raises an in-app sheet or an actionable notification; the conversation waits
  durably until the user answers.
- Providers/models are configured in Settings; keys are stored in the Keychain.

### Tool replay table (v1)

| Tool | Replay | Notes |
|---|---|---|
| `calendar_query`, `reminders_query` | safe | read-only |
| `calendar_create_event` | safe with an idempotency key | write a key into the event URL; check for it before creating |
| `reminders_create` | safe with an idempotency key | same pattern |
| `health_query` (quantity/category/summary) | safe | read-only; ask for HealthKit authorization per type |
| `notify_schedule` | safe | the notification identifier is the idempotency key |
| `list_components`, `preview_surface`, `validate_surface` | safe | |
| `create_surface`, `patch_surface`, `bind_data` | safe | version-checked document commits |
| `publish_surface` | safe | idempotent: writes the file and reloads the timeline |

## Generated native UI

### Layers

```
Layer 0  Primitives (internal + escape hatch): VStack/HStack/ZStack, Grid, Spacer,
         Text (styles, date/timer/relative), Image(systemName:), Gauge, ProgressView,
         Chart (line/bar/area/point/sector), Divider, Link, Button(intent), Toggle(intent).
Layer 1  Components (the agent's main vocabulary). Each one knows how to adapt to
         every widget size and says which sizes it can't support.
Layer 2  Surfaces: where specs render, each with slot limits and allowed components.
```

### Layer 1 component catalog (v0, ~15)

| Component | Purpose | Key props |
|---|---|---|
| `MetricTile` | one big number + label + trend | value, unit, label, trend, symbol |
| `Ring` | progress toward a goal | value, goal, symbol, tint |
| `Sparkline` | small trend line | series, range, highlight |
| `BarStrip` | small bar chart | series, labels |
| `NextUp` | next calendar event / reminder | source, showCountdown, maxItems |
| `Countdown` | time until / since | date, style, label |
| `Checklist` | reminders with toggles | source, maxItems, toggleIntent |
| `Timeline` | ordered list of time-stamped items | items, maxItems |
| `Quote` | short agent-written text | text, emphasis |
| `StatGrid` | 2–4 compact metrics | items[] |
| `Header` | title + symbol + timestamp | title, symbol, updatedAt |
| `Badge` | status pill | text, tone |
| `ActionRow` | 1–3 intent buttons | actions[] |
| `ImageCard` | image with caption | asset, caption |
| `Custom` | Layer 0 subtree (escape hatch) | tree |

### Layer 2 surfaces (v1)

| Surface | Families / context | Slots | Interactivity |
|---|---|---|---|
| Home Screen widget | systemSmall / systemMedium / systemLarge | 1 / 3 / 6 | Button/Toggle intents |
| Lock Screen widget | accessoryCircular / Rectangular / Inline | 1 / 2 / 1 (text only) | Button intents |
| Live Activity | Lock Screen + Dynamic Island (compact/minimal/expanded) | per region | Button intents |
| Control | Control Center / Lock Screen / Action Button | 1 | single intent |
| App Intent snippet | Siri / Shortcuts / Spotlight result | 3 | snippet intents |
| Chat card | inline in a conversation | unbounded (scrolls) | any |

### Spec format (sketch)

```json
{
  "schema": 1,
  "id": "srf_morning",
  "surface": "widget",
  "families": ["systemMedium", "accessoryRectangular"],
  "layout": "split",
  "slots": [
    { "c": "Ring", "value": "$health.stepsToday", "goal": 10000, "symbol": "figure.walk" },
    { "c": "NextUp", "source": "$calendar.next", "showCountdown": true },
    { "c": "Quote", "text": "$doc.nudge.text", "emphasis": "secondary" }
  ],
  "tapAction": { "intent": "OpenConversation", "conversationId": "…" },
  "refresh": { "native": "15m", "agent": { "task": "nudge", "every": "3h" } }
}
```

- `$health.*` and `$calendar.*` are **native data sources** that widgets resolve on
  their own timeline with no LLM. `$doc.*` reads values the agent wrote into a Pi
  document; PiApp exports them to `snapshots/`.
- Specs are stored as a Pi document (`defineDoc`, `history: "rewindable"`,
  `fork: "asOf"`), so each patch is a commit and undo and branching come for free.
  Publishing copies the current version to `surfaces/<id>.json` and calls
  `WidgetCenter.shared.reloadTimelines(ofKind:)`.
- The schema is versioned, and PiUI can render every schema version it has shipped.

### Agent-facing UI tools

- `list_components(surface)` → schemas, slot limits, the dial setting for that surface
- `create_surface(surface, families, spec)` → `{ id, version, warnings }`
- `patch_surface(id, baseVersion, jsonPatch)` → `{ version, warnings }`
- `bind_data(id, path, source)` → validates that the source exists and has authorization
- `validate_surface(id)` → errors written for the model to fix
  (for example "medium allows 3 slots, got 5", "Ring needs goal")
- `preview_surface(id, families, appearance)` → PNGs rendered with `ImageRenderer`
  (light/dark/tinted) + layout warnings (truncation, overflow) for the model to
  check its own work with vision
- `publish_surface(id)` → it appears in the configurable "Pi Widget"
  (`AppIntentConfiguration` with an entity query listing published surfaces)

### Generativity dial

Each surface has a level, set in code, adjustable in a debug Settings screen, and
recorded with each spec:

| Level | Name | Agent may | Typical surface |
|---|---|---|---|
| 0 | Template | pick a preset layout and fill in data/text | Lock Screen inline/circular |
| 1 | Compose | arrange Layer 1 components in surface slots | Home Screen widgets (default) |
| 2 | Compose+ | Level 1 plus `Custom` slots within a size/node budget | systemLarge, Live Activity expanded |
| 3 | Freeform | any Layer 0 tree within a node budget | chat cards, later full-screen "mini apps" |

Tuning loop: log every `Custom` subtree and every validation failure. Review them
from time to time and turn repeated `Custom` layouts into Layer 1 components or presets.
Raise or lower levels per surface based on how good the previews are. The dial must
change only validation rules and tool descriptions, never the renderer.

## Apple integrations (v1)

- **App Intents / Shortcuts / Siri**: `AskPi(prompt)`, `RunPiTask(name)`,
  `ContinueConversation`, `GetSurfaceValue`, `OpenConversation`, `RunWidgetAction(surfaceId,
  actionId)`; an `AppShortcutsProvider` with Siri phrases; `AppEntity` for conversations and
  surfaces; snippet results rendered by PiUI.
- **WidgetKit**: one configurable "Pi Widget" kind for Home Screen and Lock Screen sizes; interactive.
- **ActivityKit**: Live Activity for a running agent run (status, current tool, elapsed
  time, approve/stop buttons); Dynamic Island.
- **BackgroundTasks**: `BGContinuedProcessingTask`, `BGAppRefreshTask`.
- **UserNotifications**: run finished, approval needed (actionable), scheduled task results.
- **EventKit**, **HealthKit** (read), **CoreLocation** (on request), **Spotlight** (index
  conversations/surfaces via `IndexedEntity`).
- Later: Watch app + Smart Stack widgets (Watch is a client; iPhone owns the harness),
  WeatherKit, MapKit search, Photos, Contacts, Notes via Shortcuts, Foundation Models provider.

## Repository layout (proposed)

```
pi-durable-ios/
  project.yml                 # XcodeGen
  App/                        # PiApp target (SwiftUI, App Intents, ActivityKit, BG tasks)
  Widgets/                    # PiWidgets extension
  Packages/
    PiRuntime/                # JSContext host, polyfills, SQLite facade, env, tool bridge
    PiUI/                     # schema types, validator, renderer, previews
    PiAppleTools/             # EventKit/HealthKit/notifications handlers
  js/                         # TS: harness bootstrap, extensions, tool stubs, bridge typings
    package.json, build.ts (esbuild → App/Resources/pi-runtime.js)
    test/                     # vitest under node for pure logic; conformance runs in JSC too
  docs/specs/, docs/adr/
  scripts/                    # kill-resume test, bundle, simulator helpers
```

## Milestones

### M0 — Runtime viability (proof-of-concept tests; nothing else starts until this passes)

1. XcodeGen project, app + widget extension, App Group, signing works on a device.
   Capability check on the personal team (App Groups, HealthKit, widgets, background
   modes, Live Activities). Record results in `docs/notes/`.
2. esbuild bundle of pi-durable + pi-ai evaluated in `JSContext`; polyfills; one
   streamed Anthropic response shown in a bare SwiftUI view.
3. Swift `SqliteDatabase` facade; `SqliteStorage.open`; storage conformance passes inside JSC.
4. **Kill test**: start a long run (a model request plus a replay-safe slow tool and a
   non-replay-safe tool), `xcrun simctl terminate` the app mid-call, relaunch → `resume()`
   finishes the turn; the safe tool reruns and the unsafe one is reported as interrupted. Scripted.
5. Measurements: bundle size, cold start to `Harness.open`, idle memory, memory during a
   run, time per token. Recorded in `docs/notes/`.

Acceptance: items 1–5 pass on the simulator and on a physical iPhone.

### M1 — Chat MVP
Conversation list/detail, streaming transcript, tool call rendering, provider settings +
Keychain, abort, fork, parked-task view, diagnostics log. Calendar + Health read tools.
Approval hook with an in-app sheet.

### M2 — Component layer + widgets
PiUI schema v1, the Layer 1 catalog, validator, renderer, `ImageRenderer` previews, UI tools,
spec document, publishing, configurable Pi Widget (Home Screen + Lock Screen), native data
sources resolved in the widget, generativity dial (debug UI). Snapshot tests for every
component × size × appearance.

### M3 — System integration
App Intents + Siri phrases + snippets, Live Activity for runs, `onWake` ↔ BackgroundTasks,
actionable approval notifications, `requestId` on every entry point, scheduled agent tasks
(`sleepUntil`) that refresh `$doc.*` widget values.

### M4 — Breadth and polish
Reminders writes, location, Spotlight, Liquid Glass pass, component gallery, dial tuning
from logs. M5 (later): Watch.

## Testing

- Swift Testing for PiRuntime (facade, polyfills, bridge), PiUI (validator; snapshot tests
  of the renderer), PiAppleTools (with mocks for EventKit/HealthKit stores).
- Pi Durable's `registerStorageConformance` and `registerEnvConformance` must run **inside
  JSC** in a test host, not only under Node.
- vitest under Node for pure TS (extension logic, spec validation shared with Swift
  through JSON Schema fixtures).
- Scripted kill/resume tests on the simulator (`xcrun simctl`), run before merging changes to
  the runtime, storage or tools.
- The sample conversations/specs used for snapshot tests are checked in.

## Risks and open questions

- **JSC compatibility** (highest risk): which globals pi-ai/chord/TypeBox assume
  (streams, `TextDecoderStream`, `structuredClone`, `Intl`, `AbortSignal.timeout`,
  `crypto.subtle`). M0 finds out. Fallback: a hidden `WKWebView` host (JIT, IndexedDB
  storage), at the cost of lifecycle complexity.
- **Performance without JIT**: TypeBox validation and compaction may be slow. Measure in M0.
- **Background limits**: iOS can deny or end background time; the design relies on
  resuming correctly, not on staying alive.
- **Pi Durable is experimental**: pin versions; keep our code behind a thin adapter layer;
  read CHANGELOG before upgrades.
- **HealthKit/EventKit authorization UX** inside agent flows (ask for permission when the agent first needs it, not all at launch).
- **Widget memory limits** (~30 MB): the renderer must be lightweight; no JSC in extensions.
- **Spec schema drift** between the TS validator and the Swift renderer: one JSON Schema is the
  source of truth, generated into both or checked against shared fixtures.
- Open: should `$doc.*` snapshots update on every commit or only on publish/refresh tasks?
- Open: is Code Mode (`@earendil-works/pi-durable/codemode`) worth using later, so the agent
  can compute derived widget values in a sandbox?

## References

- Pi Durable announcement: https://earendil.com/posts/pi-durable/
- Pi 1.0: https://earendil.com/posts/pi-1-0/
- Package README (npm `@earendil-works/pi-durable@1.4.0`): sections Persist and Resume,
  Sleeping and Waking Up (the `onWake` evicted-host pattern), Tools (replay), Environment,
  Storage (portable SQLite facade, conformance suite), Your Own State (documents)
- Durable coding agent demo: https://github.com/earendil-works/pi/tree/main/packages/coding-agent/src/experimental/durable
- Prior art in this workspace: `~/Code/pi-sql` (Pi integration, resumable runs spec 0003)
