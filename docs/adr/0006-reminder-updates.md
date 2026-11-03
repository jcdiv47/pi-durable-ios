# ADR 0006 — Reminder updates and list selection

Status: accepted

## Decision

Expose `reminders_lists` (read-only) and `reminders_update` (approval required by
default). Query, create and update accept either an exact list name or a list ID.
Ambiguous names fail instead of silently selecting an account; discovery returns
account names and write access so the agent can select the intended list.

Updates set only supplied fields: title, notes, priority, due date and destination
list. Empty notes clear notes; `clearDue` removes the deadline. Changing the due
date replaces time alarms while retaining location alarms. Unspecified fields,
recurrence and the URL used for creation deduplication are preserved. Moving means
changing lists, not manual ordering or subtask nesting.

Unlike completion, updates are not marked replay-safe. A move may invalidate its
original identifier, and replaying an edit could overwrite a later user change.
After interruption the agent must query the current reminders before deciding
whether to retry. No new persistence or creation-idempotency mechanism is needed.

## Validation

PiAppleTools tests cover partial edits, moving an unsaved EventKit reminder,
unchanged fields, due-date alarm replacement, invalid edits and ambiguous lists.
These tests do not write to a user's reminder store. Account-specific move and
sync behavior still requires a device check with real writable lists.
