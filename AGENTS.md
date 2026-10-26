# pi-durable-ios

A personal, sideloaded iPhone app that runs `@earendil-works/pi-durable` in an embedded
JavaScriptCore runtime. **Read [`docs/specs/0001-pi-durable-ios.md`](docs/specs/0001-pi-durable-ios.md)
first**; it is the source of truth. M0 findings and measurements are in [`docs/notes/`](docs/notes/);
decisions that change the spec go in `docs/adr/`.

## Layout

- `project.yml`: XcodeGen spec (PiApp + PiWidgets). `PiDurable.xcodeproj`, `Info.plist` and
  `.entitlements` files are generated and git-ignored; edit `project.yml` instead.
- `App/`, `Widgets/`: app and WidgetKit extension.
- `Packages/PiRuntime`: JSContext host, polyfill natives, the sqlite3 facade, the URLSession fetch
  bridge and the Keychain key source. `PiUI` and `PiAppleTools` are stubs for M1 and M2.
- `js/`: TypeScript run inside JSC. `bun build.ts` bundles `src/runtime.ts` (the app's harness
  bootstrap) and `src/conformance.ts` (test suites) into `App/Resources/` and the PiRuntime test
  resources. pi-durable, pi-ai and chord stay pinned to the **same exact version** (1.4.0).
- `scripts/`: simulator and device drivers.

## Build and test

```sh
cd js && bun install && bun run build && npx tsc -p .   # bundle + typecheck
cd Packages/PiRuntime && swift test                      # conformance + harness tests in macOS JSC
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
- `scripts/m0-check.sh conformance|capabilities|measure|stream`: one headless mode of the app;
  prints its JSON report from `Documents/m0/`.
- `scripts/push-key.sh <provider> <file>`: moves an API key into the app's Keychain (debug builds).
  Never put keys in the repo, in launch arguments or in JS. JS only sees `pi-host-key:<provider>`,
  and Swift substitutes the real key for that provider's allowlisted hosts.

The app's modes are launch arguments (`-PiMode <mode>`); see `LaunchMode` in `App/Sources/PiApp.swift`.

## Rules of thumb

- Only PiApp opens Pi storage (`<App Group>/pi/*.sqlite`). Extensions never load JS.
- JS runs on one serial queue (`JSRuntime.queue`). Swift calls into JS only through
  `globalThis.__piHost` / `PiRuntime.*`, and stores integer handles, never `JSValue`s.
- New globals that Pi or pi-ai needs go in `js/src/host/polyfills.ts`, with a case in
  `js/test/polyfill-cases.ts`.
- The `SqliteDatabase` facade must keep passing both Pi's storage conformance suite and
  `js/test/facade-cases.ts` (Pi's suite does not exercise rollback).
