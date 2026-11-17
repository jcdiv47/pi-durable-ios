# pi-durable-ios

A personal, sideloaded iPhone app that runs `@earendil-works/pi-durable` in an embedded
JavaScriptCore runtime.

## Layout

- `project.yml`: XcodeGen spec (PiApp + PiWidgets). `PiDurable.xcodeproj`, `Info.plist` and
  `.entitlements` files are generated and git-ignored; edit `project.yml` instead.
- `App/`, `Widgets/`: app and WidgetKit extension.
- `App/Sources/Chat/`: the chat app (`ChatStore.shared` owns the Harness; conversation list, transcript,
  approval sheet, settings, diagnostics, scheduled tasks, the component gallery and design tuning). The transcript
  folds tool calls into "Worked" rows (`TranscriptRow`), draws Apple tool results as native cards (`ResultCards`,
  from `cardTools` in display.ts) and assistant text as Markdown (`MarkdownText`). The transcript's pieces draw with the
  chat's design tokens (`Design/PiDesign`: palette, radii, elevation, motion) and shared components (`Design/PiComponents`:
  `ShimmerText`, `ToolStatus`, `ToolChips` while a run works, `ContextCards` for skills and pages a run read, `DiffView`,
  `PiTable` and `RecordsTable` for JSON tool output, `PiMeter`); Settings › Widgets › Chat Components shows them all.
  Use the tokens, not ad-hoc colors and radii, in new chat views. Approvals lead with what a tool does in words (`ToolTitles`, `ApprovalDetails`), the tool's
  name second; the list groups conversations by date (`ConversationSections`), as Notes does, and its search field finds titles and
  what was said (`ConversationSearch`, over `PiRuntime.searchConversations`: the search itself is JS's, `search.ts` and
  `Chat.search`, so a search tool for the agent can call the same one; user, assistant and spoken text, never thinking
  or tool output); a hit opens the transcript at its message. The composer's mic (`VoiceInput`)
  records, and OpenAI's transcription (`gpt-transcribe`, the `openai` provider key, sent from Swift) fills the field.
  Talk to Pi (`RealtimeVoice`, `VoiceAudio`, `VoiceView`, `Route.voice`, `pidurable://voice`): a spoken session over
  OpenAI's Realtime API (WebSocket from Swift, the `openai` key). The voice model's only tool is `ask_pi`, which sends
  the request into a Pi conversation through `askFromOutside` (request ID `voice:<session>:<call_id>`), so Pi's tools,
  approvals and transcript stay Pi's; approvals are tapped, never spoken. The session itself is not durable, but what
  was said is: each spoken line goes into the conversation as a display-only `app.voice` entry (`voiceLine`, `voice.ts`;
  the model never reads it), in the order said, around the requests, whose input entry carries the session and which
  the transcript draws as "Asked Pi", not as a bubble (`VoiceTranscriptViews`). The session is recorded (`VoiceAudio`)
  as two tracks, never mixed, so no voice is in it twice: the microphone (`<session>.mic.m4a`, on the clock of the audio
  sent to OpenAI) and Pi's voice as OpenAI sent it, cut where the user cut it off (`<session>.pi.m4a`), in Application
  Support `voice/` (`VoiceRecordings`, not backed up, Settings › Talk to Pi turns it off). Lines point into their
  role's track by offset; a session's Play plays its lines in turn (`VoicePlayback`), and a back swipe stops it.
  Recordings no conversation shows are swept with the attachments (`PiRuntime.voiceSessions`).
  Links go through the root's `openURL` action: with Settings › Links on Pi, web links push `Route.browser`
  (`BrowserView`, a SwiftUI `WebPage`), so the stack's edge swipe returns to the chat.
  Settings › MCP servers (`MCPSettingsView`, `MCPServers`): the user's MCP servers, kept in Swift with their cached
  tool lists (Application Support `mcp-servers.json`) and the VPN hint (`VPNStatus`). Auth is
  none, a token, or OAuth sign-in: pi-mcp's OAuth client runs in JS, its state lives in the Keychain service
  `dev.jcdiv47.pidurable.mcp-oauth` (`MCPOAuth`, through the `mcp.oauth*` host calls), and the sign-in page is an
  `ASWebAuthenticationSession` redirecting to `dev.jcdiv47.pidurable:/oauth/mcp`.
  Settings › SSH Hosts (`SSHSettingsView`, `SSHHosts`): the user's machines (Application Support `ssh-hosts.json`), their
  passwords or keys in the Keychain service `dev.jcdiv47.pidurable.ssh` (`SSHSecrets`), host keys pinned in Settings.
  Settings › Instructions and Skills (`SkillsViews`, `Skills`): the user's AGENTS.md (Application Support `AGENTS.md`)
  and the skills imported from Files or written in the editor (`SkillEditorView`, `skills/<name>/`); the composer's "/"
  menu and chip run a skill.
  Settings › Alarms & Timers (`AlarmsView`, `pidurable://alarms`): the alarms Pi set (`PiAlarms` in PiAppleTools), counting
  down; the Clock app never shows them. A timer's Lock Screen countdown is the widget's `PiAlarmLiveActivity`, over
  PiUI's `PiAlarmMetadata`.
  Deleting a conversation (`Chat.delete`): pi-durable has no way to remove entries, so it leaves `ConversationIndex`
  for its `deleted` list, and nothing opens it again (`#conversation` refuses it); its schedules, widgets, notifications
  and Live Activity go, and the attachment and voice sweeps run at once. Forks keep what they show of it.
  Export: a conversation as Markdown (`export.ts`, `Chat.exportMarkdown`; `ConversationMarkdown` for `ShareLink`), and
  Settings › Backup & Export (`Backup`, `BackupView`): an Apple Archive of a `VACUUM INTO` copy of Pi's storage
  (`SQLiteSnapshot`), attachments, widget files, recordings, the user's files, settings and every conversation as
  Markdown; never Keychain secrets. A restore is unpacked and checked into `<App Group>/restore/`, the app exits, and
  the next launch applies it before `ChatStore.shared` reads anything (the replaced storage stays in `restore/previous/`).
  Spend (`UsageViews`): the transcript's footer shows the conversation's tokens, cost and how full its context is
  (the frame's `usage`, from `pi.usage` and the newest answer); Settings › Usage adds a month's answers across
  conversations by model (`PiRuntime.spending`, `usage.ts`; a fork counts only what it asked after forking).
  Settings › Apple Intelligence (`IntelligenceSettingsView`): the on-device model's status, on-device titles and
  notification summaries.
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
  buttons, which iOS performs in the app's process, and `TalkToPiIntent` (an `AudioRecordingIntent`: the Action button
  and Control Center start a voice session without opening the app, recording only while the voice Live Activity,
  PiUI's `PiVoiceAttributes`, shows; a second press hangs up).
- `Packages/PiRuntime`: JSContext host, polyfill natives, the sqlite3 facade, the URLSession fetch
  bridge (with `localHosts`: hosts answered in the process), `NetworkPath` (NWPathMonitor, read by JS as `__native.networkOnline()`), the Keychain key source, the async host-call bridge
  (`JSRuntime.Options.hostCall`), `AppleIntelligence` (Foundation Models as an OpenAI-compatible endpoint on
  `apple-intelligence.pi.local`, plus titles and summaries) and `SkillLibrary`
  (SKILL.md checks, import, and the `skills.*` host calls that read inside a skill's folder).
- `Packages/PiAppleTools`: EventKit, HealthKit, CoreLocation and AlarmKit (`AlarmTools`) handlers behind the JS Apple tools
  (`AppleToolHost`), and photo search (`Photos/`: `CLIPTokenizer`, `ClipEncoder` over MobileCLIP's Core ML encoders,
  `PhotoVectors`, `PhotoIndex`, `ClipModelDownload`). The app's `PhotosCard` draws the
  matches and Settings › Photo Search (`PhotoSearchSettingsView`) shows the index.
- `Packages/PiSSH`: SSH over Citadel, the app's only third-party package:
  hosts and secrets (`SSHHost`, `SSHSecret`), Ed25519 keys and fingerprints (`SSHKeys`), the job scripts
  (`SSHJobScript`), connections with pinned host keys (`SSHConnections`) and the `ssh.*` host calls (`SSHToolHost`).
- `Packages/PiUI`: generated UI (M2). The component catalog, validator, renderer (`SurfaceView`), previews,
  native data sources (`NativeData`), the App Group files (`SurfaceStore`), `SurfaceHost`, which answers the
  JS UI tools, the components' sample slots (`Gallery/`) and the dial's tuning log (`Tuning/`). Shared by the app and the widget. The catalog lives only here.
- `Widgets/`: the configurable Pi Widget (`PiWidget.swift`): shows a published surface, resolves native data on
  its timeline, runs its buttons through `RunWidgetActionIntent`. The run Live Activity (`PiRunLiveActivity.swift`). The
  Talk to Pi control and the voice Live Activity (`PiVoiceLiveActivity.swift`).
- `js/`: TypeScript run inside JSC. `bun build.ts` bundles `src/runtime.ts` (the app's harness
  bootstrap) and `src/conformance.ts` (test suites) into `App/Resources/` and the PiRuntime test
  resources. `src/app/` is the chat API Swift calls (`PiRuntime.*`): conversations, display frames,
  providers (`models.ts`, including the keyless `apple` provider; `network.ts`: a model request that fails while the
  phone is offline waits for the network and is sent again, instead of using up Pi's retries), the Apple tool stubs, the UI tools (`surfaces.ts`: specs in Pi documents, JSON Patch), scheduled tasks
  and `notify_schedule` (`schedule.ts`: day and week intervals keep their local time across daylight saving changes; a
  run that answers `NO_REPLY` posts no notification), the web tools (`web.ts`: `web_search` through DeepSeek or Brave,
  `web_fetch` through DeepSeek Fetch) over keyed HTTP services (`services.ts`), SSH tools (`ssh.ts`: `ssh_exec`, `ssh_job`), MCP servers (`mcp.ts`: a connection per
  server over `@earendil-works/pi-mcp`'s Streamable HTTP client, and the `mcp` extension), the user's instructions and skills
  (`instructions.ts`, `skills.ts`: prompt sections, `skill_read`, `skill_file`), Code Mode (`codemode.ts`: the
  `codemode` tool, scripts that call the other tools in QuickJS-wasm, read from the bundle resource `quickjs.wasm` on
  the first script), the approval gate and the offline
  `scripted/assistant` model. `chat.ts`
  also has the entry points outside the chat (`ask` from intents and notification replies, `widgetAction`,
  `runSchedule`).
  pi-durable, pi-ai, pi-schema (tool schemas), pi-mcp and chord stay pinned to the **same exact version** (1.5.0).
  `build.ts` stubs pi-mcp's stdio transport and OAuth callback server, gives its SSE reader a local `Buffer.byteLength`,
  and gives its OAuth flow and provider a local `Buffer` and SHA-256 `crypto.subtle.digest` (`src/host/pi-mcp-shims.ts`);
  never add a global `Buffer` (the provider SDKs would take their Node paths).
- `scripts/`: simulator and device drivers.

## Build and test

```sh
cd js && bun install && bun run build && npx tsc -p .   # bundle + typecheck
cd Packages/PiRuntime && swift test                      # conformance + harness + UI tool + MCP client tests in macOS JSC
cd Packages/PiUI && swift test                           # validator, host and snapshot tests
cd Packages/PiSSH && swift test                          # keys, job scripts, and commands against a local sshd
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
  checked in: about 200 MB, Apple's sample code license). Optional: without them the app downloads the model in
  Settings › Photo Search (`ClipModelDownload`); with them the app
  uses its own. `PI_MOBILECLIP=s0` for the smaller model. PiAppleTools' tests use them when present.
- `scripts/push-key.sh <provider> <file>`: moves an API key into the app's Keychain (debug builds). `brave` works
  too.
  Never put keys in the repo, in launch arguments or in JS. JS only sees `pi-host-key:<provider>`,
  and Swift substitutes the real key for that provider's allowlisted hosts. The one exception is OAuth MCP servers:
  pi-mcp's OAuth client refreshes their tokens in JS, so those tokens are in JS memory (never in a tool's output).
- `scripts/release.sh <version>`: sets `MARKETING_VERSION` in `project.yml`, adds one to `CURRENT_PROJECT_VERSION`
  (the build number), commits `project.yml` and tags it `v<version>`. It pushes nothing; it prints the push and
  `gh release create` commands. Set versions only there (every target reads the project-wide settings), never with
  `agvtool` or in an `info:` block.

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
- A new HTTP API is a service: its hosts (and a monthly cap, if its
  plan has one) in `ProviderKeys`, a key entry in `ChatStore.services`, and tools that call `serviceFetch` with the
  key placeholder in a header or a URL query. Never a generic HTTP tool: a page could use it to send data out.
- The `apple` provider is text only and has no tools; its endpoint writes its own short instructions. One-shot jobs
  (titles, summaries) fall back to the old behavior when the model is unavailable, slow or refuses. Private Cloud
  Compute needs a managed entitlement the free team lacks.
- Photo search never sends pixels, captions or locations to the model: `photos_search` returns asset IDs, dates and
  scores, and the chat draws the photos on the device. The index lives in Application Support, not the App Group.
- MCP servers are added only by the user, in Settings; no tool may add, change or remove one. A server's host gets
  its token (`mcp-<id>`) only through `ProviderKeys.setMCPHosts`, from Swift. Only the user signs in to an OAuth server,
  from Settings; a connection without tokens fails without starting a sign-in. The `mcp` extension is installed from
  the cached tool lists before the Harness opens, so interrupted calls resume without the network.
- SSH hosts are added, changed and removed only by the user, in Settings; no tool may change one. Passwords, keys and
  host keys never reach JS: JS names a host by its ID. Nothing logs in before the user trusted the host key. Every
  command is a detached job named after its tool task (`SSHJobScript`), which is what makes `ssh_exec` replay-safe;
  keep it so.
- Instructions and skills are written, edited, imported and removed only by the user, in Settings; no tool may change them, and
  a skill's scripts never run. Skill files are read only through `SkillLibrary`, which keeps paths inside the skill.
- Code Mode scripts reach only the conversation's tools; every nested call goes through the approval gate, and its
  request carries the `codemode` call's ID. QuickJS runs on the JS queue, so keep its interrupt budget: a script that
  computes holds the queue. JSC's async WebAssembly API never settles there (`polyfills.ts` wraps the synchronous
  one), and bytes in wasm memory reach Swift only through copies (`JSBytes`).
- The `SqliteDatabase` facade must keep passing both Pi's storage conformance suite and
  `js/test/facade-cases.ts` (Pi's suite does not exercise rollback).
- A new component, prop, family rule or data source goes in PiUI's catalog (`Schema/`), with a sample slot in
  `Sources/PiUI/Gallery/components.json` (the gallery and the snapshot tests both draw it) and a re-recorded
  snapshot sheet. The dial changes validation and
  `list_components` only, never the renderer. Widgets never ask for permissions; `bind_data` does, in the app.
