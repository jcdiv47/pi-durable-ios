# M2: component layer + widgets

Date: 2026-10-27. pi-durable / pi-ai / chord 1.4.0. Tested on the iPhone Air simulator (iOS 27.0) with the
offline `scripted/assistant` model and DeepSeek `deepseek-flash`. **Not yet run on the iPhone.**

## Status against the spec's M2 list

| M2 item | State | Tested by |
|---|---|---|
| PiUI schema v1 | done: `SurfaceSpec` (lenient decode), `PublishedSurface` (the widget's file) | `ValidatorTests`, snapshots |
| Layer 1 catalog | done: all 15 components, each adapting to the families it supports | snapshot sheet per component |
| Validator | done: model-worded errors at JSON Pointer paths; slot limits, bindings (source exists, kind fits), symbols, colors, Custom trees, text-length warnings | `ValidatorTests` (13) |
| Renderer | done: `SurfaceView`, shared by the widget, chat cards and previews; layouts `stack`/`row`/`split`/`grid` | snapshots, simulator Home Screen |
| `ImageRenderer` previews | done: PNG per family × appearance, plus overflow warnings | `HostTests.preview`, `SnapshotTests.overflow` |
| UI tools | done: `list_components`, `create_surface`, `patch_surface` (RFC 6902), `bind_data`, `validate_surface`, `preview_surface`, `publish_surface`, plus `set_value` for `$doc` values | `SurfaceTests` (5, in JSC), DeepSeek live |
| Spec document | done: `ui.surfaces`, conversation-scoped, `history: "rewindable"`, `fork: "asOf"` | `SurfaceTests.fork` |
| Publishing | done: `surfaces/c<conversation>-<surface>.json` + `reloadTimelines`; `ui.published` index; Unpublish in the app | `SurfaceTests.publish`, simulator |
| Configurable Pi Widget | done: `AppIntentConfiguration`, `SurfaceEntity` + query over published files; all six families | simulator: added to the Home Screen (medium) |
| Native data in the widget | done: `NativeData` reads `$health.*`, `$calendar.*`, `$reminders.*` on the timeline; `$doc` from `snapshots/values.json` | simulator (calendar); health reads 0 with no samples |
| Generativity dial (debug UI) | done: per family, Widgets › Design level; recorded with each published spec | `ValidatorTests.dial`, simulator |
| Snapshot tests, component × size × appearance | done: one sheet per component (every supported family, light/dark/tinted; Lock Screen tinted), plus the sample specs | `SnapshotTests` (macOS renders) |

## How it fits together

- **One catalog, in Swift** ([ADR 0001](../adr/0001-surface-validation-in-swift.md)). JS stores specs; PiUI's
  `SurfaceHost` checks, draws and exports them through `hostCall`.
- **Specs are Pi documents.** Each create/patch is a commit to the conversation's `ui.surfaces` document, so
  forks see surfaces as of their fork point. A published file is per conversation (`c<id>-s1`), so a fork
  that edits a shared surface publishes its own copy.
- **Replay safety.** All UI tools are `replay: "safe"`. `create_surface` finds the record its own task made
  (`createdBy`); `patch_surface` and `bind_data` remember the tasks they applied (`patchedBy`); publishing
  writes the file before the record, and both are idempotent. `SurfaceTests.crash` kills the process at the
  publish approval: one surface and one publish after the relaunch.
- **Approvals.** `publish_surface` asks by default (spec: "publish surface to the Home Screen" is a gated
  write). The sheet shows the widget being published.
- **Permissions on first use.** `bind_data` asks for the permission the bound source needs: Calendar,
  Reminders, or the one HealthKit type behind the source. The widget never asks; it reads under the app's
  grants and shows a placeholder for anything missing.
- **Text-only models.** `preview_surface` checks whether the conversation's model accepts images; if not, it
  skips rendering and returns only the layout checks (pi-ai would replace the images with placeholders).
- **Chat cards.** `surface: "card"` specs draw under the tool call that made them. A surface draws only under
  the call holding its newest version; older calls say "newer below".
- **Tuning log.** Every `Custom` tree and failed validation goes to Diagnostics (`ui.custom`, `ui.invalid`).

## Live run (DeepSeek `deepseek-flash`, simulator)

Prompt: "Design a medium widget with my steps today and my next event, then publish it." The model called
`list_components`, `current_time`, `create_surface` (valid first time), `preview_surface` (DeepSeek V4.1
Flash takes images, so it gets the rendered PNGs), `bind_data` twice (Health, then Calendar permission, each on first use), `preview_surface`
again, then `publish_surface` (approved). Result: a `MetricTile` + `NextUp` with countdown, `refresh: 30m`,
`tapAction: conversation`. It then told the user how to add the widget.

One finding fixed after the run: HealthKit returns no sum for a day without samples, so steps read as missing
and the model blamed permissions. Today's totals now read 0 (HealthKit cannot tell "not allowed" from "none"
anyway).

## Other findings

- `ImageRenderer` cannot draw platform-backed controls (`ProgressView` renders as a "prohibited" box), so
  the `Progress` primitive is drawn with shapes. Gauges with accessory styles and Swift Charts render fine.
- Snapshot references are macOS renders (2.1 MB for 19 sheets at 1×). They are compared with a 0.2% pixel
  tolerance; re-record with `PI_RECORD_SNAPSHOTS=1 swift test` after an intended change or an OS update.
- Bundle: 1.54 MB (+14 KB for the UI tools).
- The M0 placeholder widget is gone; the Pi Widget replaced it.

## Not done / next

- Run on the iPhone; add a Lock Screen widget there (the simulator check covered the Home Screen only; Lock
  Screen families are covered by previews and snapshots).
- Interactive widgets (`ActionRow` buttons and `Checklist` toggles as App Intents) are M3; `ActionRow` opens
  links for now. `$doc` values refresh only when the agent calls `set_value`; scheduled refreshes are M3.
- Open question from the spec, answered for now: `$doc` values are exported on every `set_value` (and once
  at launch), not only on publish.
- `ImageCard` takes an SF Symbol only; photos come later.
