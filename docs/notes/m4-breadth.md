# M4: breadth and polish

Date: 2026-10-27. pi-durable / pi-ai / chord 1.4.0. Tested on the iPhone Air simulator (iOS 27.0) with the offline
`scripted/assistant` model. **Not yet run on the iPhone.**

## Status against the spec's M4 list

| M4 item | State | Tested by |
|---|---|---|
| Reminders writes | done: `reminders_create` (replay-safe through the tool task's idempotency key, asks by default), `reminders_complete` (sets a state, so a rerun is harmless; runs without asking by default); `reminders_query` returns IDs | `ChatTests.reminderCreate`, `ValidatorTests.actionIds`; simulator: "todo" created a reminder after Allow |
| Checklist rows bound to `$reminders.*` (left read-only in M2/M3) | done: a row completes its reminder. The app does it in Swift, with no model run, then reloads the widget | simulator: a Home Screen widget of `$reminders.open`; the tapped reminder was completed and left the list |
| Location | done: `location_current`, one fix per call (`CLLocationUpdate` under a When In Use `CLServiceSession`), the place from `MKReverseGeocodingRequest` | simulator: coordinates, and the address for a location in Shanghai (see findings) |
| Spotlight | done: `ConversationEntity` and `PublishedSurfaceEntity` are `IndexedEntity`s. Conversations are indexed with their messages' text (the first 4,000 characters), widgets with their title. A result opens through `OpenConversationIntent` / `OpenSurfaceIntent` | simulator: "Where am" in Home Screen search found the conversation, and the result opened it |
| Liquid Glass pass | done: the composer, Send/Stop and approval sheet were already glass; the inline Allow/Deny and the empty list's button are glass now. The Live Activity and tool-call rows stay as they were (system glass; content) | simulator |
| Component gallery | done: Widgets › Component gallery. Each component in every family it supports, in light, dark and tinted, with sample data or your own; its props; its design level per family | simulator |
| Dial tuning from logs | done as tooling: every validation and publish goes to a tuning log (`tuning.jsonl`). Widgets › Design tuning shows each family's failure rate next to its level, groups repeated Custom layouts by shape and errors by pattern, and suggests changes | `TuningTests` (4); simulator ("repair": one failure, then the fix) |

## How it fits together

- **Reminder rows are actions by ID.** `SurfaceAction.completeReminder(id:)` has action ID `r<slot>.<EventKit ID>`,
  not a position, because the list can change between the render and the tap. `SurfaceSpec.action(_:)` resolves it
  only for a Checklist bound to `$reminders.*`, so a widget can still only do what its spec says. Completing is
  idempotent, so the widget request ID is only logged.
- **Sample slots are a PiUI resource** (`Gallery/components.json`, `ComponentSamples`). The snapshot tests draw
  them, so the gallery shows what the reference sheets check.
- **The tuning log** records every `ui.validate` call (create, patch and validate_surface), passing or not, with
  each family's level at the time, plus publishes. A family failing ≥ 40% of ≥ 5 validations, ≥ 3 refused Custom
  slots, an unused Compose+/Freeform level, or a Custom shape seen ≥ 3 times each produce a suggestion. Nothing
  changes the dial automatically. Custom trees and failures still go to Diagnostics too.
- **Spotlight sync** runs at launch, when the list changes, when a watched run ends (the text grew, though
  `updatedAt` did not), and after a publish. It re-reads only conversations whose `updatedAt` changed (up to 40 per
  pass), remembers what it indexed in UserDefaults, and removes conversations that are gone.

## Findings

- **Reverse geocoding depends on the Mac's region.** On this machine MapKit goes to AutoNavi (China), which answers
  "no results" (GEOErrorDomain -8) for the default Cupertino location. Coordinates still come back; the place is
  just missing. A Shanghai location returned the address.
- **Spotlight matched the title, not the indexed message text.** Search text that appears only in a conversation's
  messages ("Nanjing") found nothing on the simulator. The description under the result does show the text. Check
  on the iPhone; if the body is still not searchable, put key phrases into the title or keywords.
- Bundle: 1.60 MB (1.59 MB after M3).
- Kill test and stream kill test pass on the simulator after these changes.

## Not done / next

- Run on the iPhone: everything above, plus M2/M3's device list. Location there asks for permission (the simulator
  run used `simctl privacy grant`).
- Dial tuning is tooling only; there is no real usage log to tune from yet. Review Design tuning after a few
  weeks of use.
- Spotlight indexes up to 4,000 characters per conversation; tool results are not indexed.
- M5: Watch.
