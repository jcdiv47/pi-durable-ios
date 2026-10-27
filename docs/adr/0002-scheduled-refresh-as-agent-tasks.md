# ADR 0002: Scheduled widget refreshes are agent tasks, not a spec field

Date: 2026-10-27. Status: accepted. Spec: 0001, "Spec format (sketch)" (`refresh.agent`) and M3 "scheduled agent
tasks (`sleepUntil`) that refresh `$doc.*` widget values".

## Context

The spec's sketch puts the agent's refresh in the surface: `"refresh": { "native": "15m", "agent": { "task":
"nudge", "every": "3h" } }`. Publishing would then have to create, change or remove a durable task as a side
effect, keyed by surface, and decide what the task does from a name alone. Unpublishing, forks (a published
surface is per conversation) and republishing with a new interval would each need rules. The agent also wants
schedules that have nothing to do with a widget: briefings, follow-ups, "check again tonight".

## Decision

A schedule is its own durable task, `app.scheduled` (`js/src/app/schedule.ts`), created by the agent with the tool
`schedule_task(name, prompt, at?, every?, notify?)`. The conversation owns it as a background task: Stop does not
cancel it, and idle waits do not wait for it. Each run sleeps (`runtime.sleepUntil`), then submits its prompt to the
conversation with the request ID `schedule-<task>-<run>`, waits for the answer, optionally posts it as a notification
(identifier = the same key), and sleeps until the next slot. To refresh a widget, the prompt says which `set_value`
to call. `refresh.native` stays in the spec; `refresh.agent` is not read, and the validator says to use
`schedule_task` instead.

`schedule_task` asks for approval by default: a schedule runs the model unattended, on the user's key.

## Consequences

- Surfaces stay pure data; publishing has no task side effects.
- One mechanism for every timed agent run, visible in one place (Scheduled Tasks screen, `RunPiTask` intent).
- The link between a widget and the schedule that feeds it is only in the prompt. Deleting a conversation cancels
  its schedules; unpublishing a widget does not.
- Runs missed while iOS kept the app asleep are skipped, not caught up: the next run is the first slot after now.
