# 003 — Let the approval section enter the conversation list instead of teleporting

- **Status**: DONE
- **Commit**: 310e004
- **Severity**: LOW
- **Category**: Missed opportunity
- **Estimated scope**: 1 file, 1 line

## Problem

`App/Sources/Chat/ChatRootView.swift:160` — `if !store.approvals.isEmpty { Section { … } }` appears and disappears at
the top of the list with no transaction, so every row below jumps by a section's height. Approvals are occasional and
the jump is what draws the eye, so a brief standard animation prevents a jarring change.

## Target

On the `List` in `ConversationListView.list`:

```swift
.animation(.snappy, value: store.approvals.map(\.id))
```

`.snappy` is the app's one curve everywhere else (composer, cards, disclosures).

## Steps

1. Add the modifier after `.listStyle(.insetGrouped)`.

## Boundaries

- Do NOT animate on `startedConversations`: reordering after every reply is high-frequency.

## Verification

- **Mechanical**: builds.
- **Feel check**: trigger an Ask-policy tool, go back to the list: the orange row slides in and rows below move down;
  answering it collapses the section smoothly.
- **Done when**: no visible jump.
