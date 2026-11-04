# pi-durable-ios

A personal, sideloaded iPhone app that runs `@earendil-works/pi-durable` in an embedded
JavaScriptCore runtime. **Read [`docs/specs/0001-pi-durable-ios.md`](docs/specs/0001-pi-durable-ios.md)
first**; it is the source of truth. M0 findings and measurements are in [`docs/notes/`](docs/notes/);
decisions that change the spec go in `docs/adr/`.

## Layout

- `project.yml`: XcodeGen spec (PiApp + PiWidgets). `PiDurable.xcodeproj`, `Info.plist` and
  `.entitlements` files are generated and git-ignored; edit `project.yml` instead.
- `App/`, `Widgets/`: app and WidgetKit extension.
- `App/Sources/Chat/`: the chat app (`ChatStore.shared` owns the Harness; conversation list, transcript,
  approval sheet, settings, diagnostics, scheduled tasks, the component gallery and design tuning). The transcript
  folds tool calls into "Worked" rows (`TranscriptRow`), draws Apple tool results as native cards (`ResultCards`,
  from `cardTools` in display.ts) and assistant text as Markdown (`MarkdownText`). The composer's mic (`VoiceInput`)
  records, and OpenAI's transcription (`gpt-transcribe`, the `openai` provider key, sent from Swift) fills the field.
  Links go through the root's `openURL` action: with Settings › Links on Pi, web links push `Route.browser`
  (`BrowserView`, a SwiftUI `WebPage`), so the stack's edge swipe returns to the chat.
  Settings › MCP servers (`MCPSettingsView`, `MCPServers`): the user's MCP servers, kept in Swift with their cached
  tool lists (Application Support `mcp-servers.json`), the VPN hint (`VPNStatus`) and the chat's warning banner.
  Settings › Instructions and Skills (`SkillsViews`, `Skills`): the user's AGENTS.md (Application Support `AGENTS.md`)
  and imported skills (`skills/<name>/`); the composer's "/" menu and chip run a skill
  ([ADR 0007](docs/adr/0007-instructions-and-skills.md)).
  Settings › Apple Intelligence (`IntelligenceSettingsView`): the on-device model's status, on-device titles and
  notification summaries ([ADR 0008](docs/adr/0008-apple-intelligence.md)).
  `App/Sources/M0/`: the headless check modes.
- `App/Sources/System/`: M3's system integration: App Intents, entities, Siri phrases and snippets
  (`PiAppIntents`), BackgroundTasks from `onWake` (`BackgroundWork`), notifications with actions (`Notifications`),
  the run Live Activity (`RunActivities`), Spotlight indexing of conversations and widgets (`SpotlightIndex`).
- `Share/`: the PiShare extension (`ShareViewController`): images, text, links and files from other apps' share
  sheets, a prompt and a conversation, written to the App Group inbox (`ShareInbox`); then it opens
  `pidurable://share/<id>` and PiApp sends the item (`ChatStore.receiveShares`, request ID `share:<id>`) or puts it in
  the composer.
- `Shared/Attachments/`: compiled into the app and the share extension: preparing attachments (images downscaled
  to JPEG in `<App Group>/attachments/`, PDF and text file text), the share inbox, and the chips both draw. JS turns
  them into the message (`js/src/app/attachments.ts`); the input entry's data keeps what the transcript shows.
  `ChatStore.sweepAttachments` deletes image files over a day old that nothing points at; a new place that keeps an
  image file name must be added to what it keeps.
- `Shared/Sources/`: compiled into the app and the widget: the `LiveActivityIntent`s behind widget and Live Activity
  buttons, which iOS performs in the app's process.
- `Packages/PiRuntime`: JSContext host, polyfill natives, the sqlite3 facade, the URLSession fetch
  bridge (with `localHosts`: hosts answered in the process), the Keychain key source, the async host-call bridge
  (`JSRuntime.Options.hostCall`), `AppleIntelligence` (Foundation Models as an OpenAI-compatible endpoint on
  `apple-intelligence.pi.local`, plus titles and summaries) and `SkillLibrary`
  (SKILL.md checks, import, and the `skills.*` host calls that read inside a skill's folder).
- `Packages/PiAppleTools`: EventKit, HealthKit and CoreLocation handlers behind the JS Apple tools
  (`AppleToolHost`), and photo search (`Photos/`: `CLIPTokenizer`, `ClipEncoder` over MobileCLIP's Core ML encoders,
  `PhotoVectors`, `PhotoIndex`; [ADR 0010](docs/adr/0010-photo-search.md)). The app's `PhotosCard` draws the
  matches and Settings › Photo Search (`PhotoSearchSettingsView`) shows the index.
- `Packages/PiUI`: generated UI (M2). The component catalog, validator, renderer (`SurfaceView`), previews,
  native data sources (`NativeData`), the App Group files (`SurfaceStore`), `SurfaceHost`, which answers the
  JS UI tools, the components' sample slots (`Gallery/`) and the dial's tuning log (`Tuning/`). Shared by the app and the widget. The catalog lives only here ([ADR 0001](docs/adr/0001-surface-validation-in-swift.md)).
- `Widgets/`: the configurable Pi Widget (`PiWidget.swift`): shows a published surface, resolves native data on
  its timeline, runs its buttons through `RunWidgetActionIntent`. The run Live Activity (`PiRunLiveActivity.swift`).
- `js/`: TypeScript run inside JSC. `bun build.ts` bundles `src/runtime.ts` (the app's harness
  bootstrap) and `src/conformance.ts` (test suites) into `App/Resources/` and the PiRuntime test
  resources. `src/app/` is the chat API Swift calls (`PiRuntime.*`): conversations, display frames,
  providers (`models.ts`, including the keyless `apple` provider), the Apple tool stubs, the UI tools (`surfaces.ts`: specs in Pi documents, JSON Patch), scheduled tasks
  and `notify_schedule` (`schedule.ts`), the web tools (`web.ts`: `web_search` through DeepSeek or Brave,
  `web_fetch` through DeepSeek Fetch) over keyed HTTP services (`services.ts`), MCP servers (`mcp.ts`: a Streamable
  HTTP client and the `mcp` extension, [ADR 0006](docs/adr/0006-mcp-servers.md)), the user's instructions and skills
  (`instructions.ts`, `skills.ts`: prompt sections, `skill_read`, `skill_file`), the approval gate and the offline
  `scripted/assistant` model. `chat.ts`
  also has the entry points outside the chat (`ask` from intents and notification replies, `widgetAction`,
  `runSchedule`).
  pi-durable, pi-ai, pi-schema (tool schemas) and chord stay pinned to the **same exact version** (1.5.0).
- `scripts/`: simulator and device drivers.

## Build and test

```sh
cd js && bun install && bun run build && npx tsc -p .   # bundle + typecheck
cd Packages/PiRuntime && swift test                      # conformance + harness + UI tool + MCP client tests in macOS JSC
cd Packages/PiUI && swift test                           # validator, host and snapshot tests
xcodegen generate                                        # then open PiDurable.xcodeproj, or:
scripts/m0-check.sh conformance                          # same suites inside the app's JSC (simulator)
```

The Xcode build runs `bun build.ts` itself (the "Bundle JS" phase).

Scripts target the booted simulator by default, `PI_SIMULATOR=<udid>` for another one, or
`PI_DEVICE=<udid>` for an iPhone (unlocked; `xcrun devicectl list devices`). `--no-build` skips
build and install. `PI_CONFIGURATION=Release` builds Release.

- `scripts/kill-test.sh`: **the kill test.** Starts a turn whose model calls a replay-safe tool
  (`slow_lookup`) and a non-replay-safe one (`send_message`), kills the app mid-call
  (`simctl terminate` / `devicectl … terminate --kill`), relaunches it, and checks that `resume()`
  finishes the turn: the safe tool reruns and the unsafe one comes back as interrupted. Run it
  before merging anything that touches the runtime, storage or the harness bootstrap.
- `scripts/stream-kill.sh`: the same for a model answer cut off **mid-stream**: kills the app once
  streamed text is committed and checks that the relaunch re-sends the request and finishes the turn.
  Offline by default; `PI_MODEL=deepseek/deepseek-flash` for a real provider.
- `scripts/m0-check.sh conformance|capabilities|measure|stream`: one headless mode of the app;
  prints its JSON report from `Documents/m0/`. (`stream` is M0's bare view, `-PiMode stream`; the
  default launch is the chat app.)
- `scripts/fetch-mobileclip.sh`: downloads MobileCLIP-S2's encoders and the CLIP tokenizer into `App/Models/` (not
  checked in: about 210 MB, Apple's sample code license). Without them the app still builds and `photos_search` says
  the model is missing. `PI_MOBILECLIP=s0` for the smaller model. PiAppleTools' tests use them when present.
- `scripts/push-key.sh <provider> <file>`: moves an API key into the app's Keychain (debug builds). `brave` works
  too.
  Never put keys in the repo, in launch arguments or in JS. JS only sees `pi-host-key:<provider>`,
  and Swift substitutes the real key for that provider's allowlisted hosts.

The app's modes are launch arguments (`-PiMode <mode>`); see `LaunchMode` in `App/Sources/PiApp.swift`.

The simulator has no BGTaskScheduler (submits fail with code 1, logged in Diagnostics); background launches can
only be checked on the iPhone. App Shortcuts run from Spotlight on the simulator (Home Screen › Search › "Ask Pi");
there is no Shortcuts app. A notification's actions: swipe it left in Notification Center, tap View.

Driving the chat UI on the simulator: Xcode 27 beta ships no Simulator.app and XCTest-based tap
tools fail, but `axe` (Homebrew) works: `axe describe-ui`, `axe tap -x … -y … --tap-style physical`
(the default tap style does not reach SwiftUI buttons), and `axe type` in chunks of a few characters
with short pauses (fast typing drops characters). Pause after focusing a field before typing.

PiUI snapshot tests compare against `Packages/PiUI/Tests/PiUITests/Snapshots/*.png` (macOS renders). After an
intended rendering change, re-record with `PI_RECORD_SNAPSHOTS=1 swift test` and look at the changed sheets.

## Rules of thumb

- Only PiApp opens Pi storage (`<App Group>/pi/*.sqlite`). Extensions never load JS.
- JS runs on one serial queue (`JSRuntime.queue`). Swift calls into JS only through
  `globalThis.__piHost` / `PiRuntime.*`, and stores integer handles, never `JSValue`s.
- New globals that Pi or pi-ai needs go in `js/src/host/polyfills.ts`, with a case in
  `js/test/polyfill-cases.ts`.
- A new Apple tool is a JS stub in `js/src/app/apple.ts` calling `hostCall(name, args)` plus a
  handler in `AppleToolHost`. Reads are `replay: "safe"`; a write is safe only with an idempotency
  key (see `calendar_create_event`), and gets an approval policy in `defaultPolicies` if the user
  should see it first. Ask for OS permission inside the handler, on first use.
- Every entry point outside the chat (intent, widget or Live Activity button, notification action, schedule) carries
  a request ID derived from its invocation and payload, never a fresh UUID, so a repeated delivery is one request.
  Notification identifiers are idempotency keys too.
- Entry points that may run while the app is away call `ChatStore.ready()` (Pi may not be open yet) and wait for
  idle before returning, or iOS suspends the app mid-run.
- A new HTTP API is a service ([ADR 0004](docs/adr/0004-http-api-services.md)): its hosts (and a monthly cap, if its
  plan has one) in `ProviderKeys`, a key entry in `ChatStore.services`, and tools that call `serviceFetch` with the
  key placeholder in a header or a URL query. Never a generic HTTP tool: a page could use it to send data out.
- The `apple` provider is text only and has no tools; its endpoint writes its own short instructions. One-shot jobs
  (titles, summaries) fall back to the old behavior when the model is unavailable, slow or refuses. Private Cloud
  Compute needs a managed entitlement the free team lacks.
- Photo search never sends pixels, captions or locations to the model: `photos_search` returns asset IDs, dates and
  scores, and the chat draws the photos on the device. The index lives in Application Support, not the App Group.
- MCP servers are added only by the user, in Settings; no tool may add, change or remove one. A server's host gets
  its token (`mcp-<id>`) only through `ProviderKeys.setMCPHosts`, from Swift. The `mcp` extension is installed from
  the cached tool lists before the Harness opens, so interrupted calls resume without the network
  ([ADR 0006](docs/adr/0006-mcp-servers.md)).
- Instructions and skills are written, imported and removed only by the user, in Settings; no tool may change them, and
  a skill's scripts never run. Skill files are read only through `SkillLibrary`, which keeps paths inside the skill.
- The `SqliteDatabase` facade must keep passing both Pi's storage conformance suite and
  `js/test/facade-cases.ts` (Pi's suite does not exercise rollback).
- A new component, prop, family rule or data source goes in PiUI's catalog (`Schema/`), with a sample slot in
  `Sources/PiUI/Gallery/components.json` (the gallery and the snapshot tests both draw it) and a re-recorded
  snapshot sheet. The dial changes validation and
  `list_components` only, never the renderer. Widgets never ask for permissions; `bind_data` does, in the app.
