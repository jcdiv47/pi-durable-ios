# ADR 0003: Defer the Apple Watch

Date: 2026-10-27. Status: accepted. Spec: 0001, "Decisions already made" (iPhone only, Watch later) and the M4 line
"M5 (later): Watch".

## Context

The spec planned a Watch app and Smart Stack widgets as M5, with the Watch as a client of the iPhone's harness. None
of M1–M4 has run on the iPhone yet, and the free Personal Team's 7-day profiles and per-week App ID limit make every
extra target costly (a Watch app adds at least one App ID). Getting context into Pi from other apps matters more day
to day.

## Decision

The Watch is deferred with no milestone. M5 is now "Context in": a share extension and composer attachments.
PiUI keeps no Watch-specific code paths.

## Consequences

- No WatchConnectivity, watchOS target or Watch complications until this ADR is superseded.
- If the Watch comes back, it stays a client: the iPhone owns Pi storage and the harness, as the spec's process
  ownership rules say.
