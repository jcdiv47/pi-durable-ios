# M1: chat MVP

Date: 2026-10-27. pi-durable / pi-ai / chord 1.4.0. Tested on the iPhone 17 Pro simulator (iOS 26.5)
with DeepSeek `deepseek-flash` and the offline `scripted/assistant` model. **Not yet run on the iPhone.**

## Status against the spec's M1 list

| M1 item | State | Tested by |
|---|---|---|
| Conversation list / detail | done: create, rename, hide (swipe), relative times, busy spinner | simulator UI |
| Streaming transcript | done: frames of appended entries + live partial (~10/s) | `ChatTests.echo`, simulator |
| Tool call rendering | done: one card per call, merged with its result and live status | simulator |
| Provider settings + Keychain | done: Anthropic, OpenAI, OpenRouter, DeepSeek, custom OpenAI-compatible endpoint; default model; per-conversation model menu | DeepSeek only (no other keys on hand); custom endpoint untested live |
| Abort | done: Stop button; partial kept, marked "Stopped" | `ChatTests.forkAndAbort`, simulator with DeepSeek |
| Fork | done: "Fork from here" on any message | `ChatTests.forkAndAbort`, simulator with DeepSeek |
| Parked-task view | done: Diagnostics › Tasks, Retry for `restart_limit`, swipe to abort | `ParkedTaskTests` (API); the screen only with no live tasks |
| Diagnostics log | done: `onReport`, sleep wakes, app events and failures; JSONL in Application Support, last 1000 | simulator |
| Calendar + Health read tools | done: `calendar_query`, `reminders_query`, `health_query`, `current_time`, plus `calendar_create_event` | simulator, each with its first-use permission prompt |
| Approval hook with an in-app sheet | done: per-tool policy auto/ask/deny, sheet + inline buttons | `ChatTests.approval`, `ChatTests.approvalAcrossCrash`, simulator across two kills |

## How it fits together

- JS (`js/src/app/`) owns the logic: `Chat` wraps the Harness, `FrameBuilder` turns each `viewState()`
  revision into a frame carrying only new entries (they are immutable) plus the small live state.
  Swift (`ChatStore`) applies frames to an `@Observable` per conversation. Bridging cost stays flat as
  transcripts grow.
- Conversation titles and the list live in a session document, `app.conversations`. Pi has no
  delete, so "Delete" aborts the conversation's work and hides it; history stays in storage.
- Apple tools are JS stubs that `hostCall()` into Swift (`AppleToolHost`), which answers off the JS
  queue. Permission is requested inside the handler on first use (spec risk "authorization UX").
- `calendar_create_event` is `replay: "safe"` with an idempotency key: the event's URL is
  `pidurable://event/task-<toolTaskId>`, and a rerun finds that event instead of adding another.

## Approvals survive the process

The gate is a `beforeTool` hook. The answer is stored with the tool task's `memo`, so once given it
holds across restarts. A hook still waiting when the process dies runs again on resume (the tool
task's `call` phase reruns from its top, and intent is not yet recorded), so the request reappears.
Checked in the simulator: ask → kill → relaunch (sheet back) → rebuild + reinstall (sheet back) →
Allow → calendar permission prompt → one event created.

## Kill mid-stream (M0 recommendation 5)

`scripts/stream-kill.sh` passes offline and with DeepSeek:

| Model | Committed at the kill | After relaunch |
|---|---|---|
| `scripted/assistant` | 272 chars | resumed in 10.8 s; 4,730-char answer |
| `deepseek/deepseek-flash` | 732 chars | resumed in 5.9 s; 7,912-char answer |

In both runs the transcript is `user, assistant(aborted), assistant(stop)`, with one user message:
re-sending the `requestId` found the admitted one. Pi keeps the cut-off partial as an aborted entry
and asks the model again from scratch, so the UI labels such an entry "Interrupted when Pi was
closed; asked again" rather than "Stopped". A kill before the first partial commit leaves no
aborted entry, only the re-sent answer.

## Other findings

- **Bundle: 1.53 MB** (from 1.21 MB). OpenAI and OpenRouter providers added ~320 KB, 251 KB of it
  OpenRouter's static model catalog. Acceptable for now. If evaluation time matters, the catalog can
  be dropped in favour of `refreshModels()`.
- A provider's keys reach pi-ai only as the `pi-host-key:<provider>` placeholder, as in M0. The
  custom endpoint's key may only go to the host of its configured base URL (`ProviderKeys.setCustomHost`).
- `onWake` flips between active and idle on every run; only wakes with a sleep deadline (`at`) are
  logged now. M3 arms BackgroundTasks from those.
- While any conversation is busy the app holds a `beginBackgroundTask` grace period. That is all the
  background execution M1 has; `BGContinuedProcessingTask` is M3.
- Swift tests: 10 (5 from M0, plus echo, approval, approval across a crash, fork + abort, park + retry),
  all in macOS JSC.

## Not done / next

- Run `stream-kill.sh`, `kill-test.sh` and a manual chat pass on the iPhone.
- Live tests of Anthropic, OpenAI, OpenRouter and a custom endpoint (no keys on this machine).
- Thinking level per conversation, conversation search, and compaction controls are not in the UI.
- Approval requests while the app is in the background have no notification yet (M3, actionable
  notifications).
