# M3: system integration

Date: 2026-10-27. pi-durable / pi-ai / chord 1.4.0. Tested on the iPhone Air simulator (iOS 27.0) with the offline
`scripted/assistant` model and DeepSeek `deepseek-flash`. **Not yet run on the iPhone**, and the simulator has no
BGTaskScheduler, so every BackgroundTasks path below is untested.

## Status against the spec's M3 list

| M3 item | State | Tested by |
|---|---|---|
| App Intents + Siri phrases | done: `AskPi`, `ContinueConversation`, `OpenConversation`, `RunPiTask`, `GetSurfaceValue`, `ShowSurface`, plus `RunWidgetAction` and the Live Activity's Approve / Stop; entities for conversations, scheduled tasks and published widgets; four App Shortcuts with phrases | simulator: Ask Pi and Show Pi Widget run from Spotlight (DeepSeek answered Ask Pi); metadata lists all 9 intents |
| Snippets | done: answers (with the card a run made) and published widgets drawn by PiUI | simulator (Spotlight) |
| Live Activity for runs | done: status, running tool, elapsed time, Allow / Deny for a waiting approval, Stop; Dynamic Island compact / minimal / expanded | simulator: Lock Screen + compact island; Allow on the activity ran the tool |
| `onWake` ↔ BackgroundTasks | done: `at` arms `BGAppRefreshTask`; leaving the foreground with runs asks for `BGContinuedProcessingTask` and arms a `BGProcessingTask`; background launches open Pi, `resume()`, wait for idle | **untested** (simulator: "BGTaskScheduler is not available"); the JS side (in-process wake timer) by `EntryPointTests` |
| Actionable approval notifications | done: Allow / Deny on the notification, answered approvals removed, answers that arrive before the relaunched hook asks again are kept | simulator; `EntryPointTests.earlyApproval` |
| `requestId` on every entry point | done: intents (intent + payload hash + minute), widget buttons (surface + action + timeline entry), notification replies (notification + text), schedules (task + run); outside requests map to the conversation they started | `EntryPointTests.askFromOutside`, `.widgetToggle` |
| Scheduled agent tasks (`sleepUntil`) refreshing `$doc` | done: `schedule_task`, `list_scheduled_tasks`, `cancel_scheduled_task`, durable `app.scheduled` task, Scheduled Tasks screen; plus `notify_schedule` for reminders ([ADR 0002](../adr/0002-scheduled-refresh-as-agent-tasks.md)) | `EntryPointTests.schedule`, `.scheduleAcrossCrash`; simulator |
| Interactive widgets (carried over from M2) | done: ActionRow buttons that send a prompt or set a `$doc` value, Checklist rows that toggle a `$doc` list | simulator: toggle and prompt from the Home Screen widget |

## How it fits together

- **One store per process.** `ChatStore.shared` owns Pi. The scene, App Intents, notification actions, widget and
  Live Activity buttons and background launches all call `ensureStarted()`, and whichever comes first opens Pi.
- **Entry points** go through `PiRuntime.askFromOutside` / `widgetAction` / `runSchedule` (js/src/app/chat.ts). An
  input from outside the chat is a custom entry, `app.input` with an `origin`, and the transcript shows its source
  ("Siri & Shortcuts", "Widget: Habits › Plan", "Scheduled: nudge"). A request that starts a conversation records
  `requestId → conversation` in the same commit (`app.requests`), so a retry finds both. A direct widget change
  (`set`, `toggle`) records its request ID too, so a tap delivered twice changes the value once.
- **Buttons outside the app** (widget, Live Activity) are `LiveActivityIntent`s in `Shared/Sources`, compiled into
  both targets: iOS performs them in the app's process. The widget hands over only the action's ID; the app reads the
  action back from the published spec (`SurfaceSpec.action(_:)`). If one ever ran without the app's handler, the
  request waits in the App Group (`inbox/intents.json`) until the app drains it.
- **Wakes.** With `onWake`, Pi arms no timers. JS keeps an in-process timer for the earliest sleep, and Swift arms
  `BGAppRefreshTask` for the same moment. Background launches and notification actions wait until Pi reports
  nothing active (up to 25 s), so iOS does not suspend the app mid-run.
- **Notifications** are posted for approvals and finished runs only while the app is away. Identifiers are
  idempotency keys: `approval-<task>`, `answer-<conversation>-<entry>`, `schedule-<task>-<run>`, `pi-c<conv>-<id>`.
  Permission is requested with the first message sent (or by `notify_schedule`).

## Findings

- **The frame right after a send can still show the conversation idle**: the input is admitted before its run starts.
  The first version ended the new Live Activity at once, showing the previous answer. An activity now ends only after
  its run has been seen busy.
- **A notification action returns before the run finishes.** After Allow, no "answered" notification came, so iOS
  probably suspended the app mid-run. The run finished at the next launch. Entry points that act while the app is
  away now wait for idle; with that, the Live Activity's Allow ran the tool and posted the answer.
- **`ImageRenderer` draws `Link` as a "prohibited" box.** The M2 ActionRow reference snapshot showed exactly that,
  and so did the model's `preview_surface` images of link buttons. Previews and snapshots now draw links as their
  label (`surfaceIsStill`); the ActionRow sheet was re-recorded.
- **Continued processing is requested on `inactive`.** That is the last moment the app counts as foreground. System
  alerts also make the scene inactive (the notification and HealthKit prompts), so on a device the system's progress
  UI may appear during a run while the app is still open. It ends with the run. Check on the iPhone.
- The notification Allow action uses `.authenticationRequired`; on a locked phone it asks for Face ID first.
- Bundle: 1.59 MB (+37 KB: schedules, entry points).

## Not done / next

- Run on the iPhone: BackgroundTasks (refresh at a sleep, continued processing, processing), the Live Activity's
  Dynamic Island expanded view, Siri by voice, the Allow action under Face ID. Re-run `kill-test.sh` and
  `stream-kill.sh` there.
- Checklist rows bound to `$reminders.*` are read-only until Reminders writes (M4).
- No Control Center control yet (the spec's Layer 2 lists one; M3 does not).
- No share sheet entry point (no share extension).
- Intent request IDs bucket by minute: the same prompt asked twice within a minute is one request.
- Spotlight indexing of conversations and surfaces (`IndexedEntity`) is M4.
