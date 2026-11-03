# 001 — Drop the queue card's slide under Reduce Motion

- **Status**: DONE
- **Commit**: 310e004
- **Severity**: MEDIUM
- **Category**: Accessibility
- **Estimated scope**: 1 file, ~3 lines

## Problem

`App/Sources/Chat/ConversationView.swift:410` — the queued-messages card moves up from the bottom edge whatever the
user's Reduce Motion setting:

```swift
.glassEffect(.regular, in: .rect(cornerRadius: 20))
.transition(.move(edge: .bottom).combined(with: .opacity))
```

Reduced motion means fewer position changes, not zero feedback.

## Target

```swift
.transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
```

with `@Environment(\.accessibilityReduceMotion) private var reduceMotion` on `ConversationView`.

## Repo conventions to follow

`ConversationWorkingStatus` (`App/Sources/Chat/ChatRootView.swift:240`) reads `accessibilityReduceMotion` the same way.

## Steps

1. Add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` to `ConversationView`'s properties.
2. Replace the `.transition` on `queue` with the target line.

## Boundaries

- Do NOT change the composer's `.animation(.snappy, value: state.queue)`.
- If the code differs from the excerpt, STOP and report.

## Verification

- **Mechanical**: the PiApp scheme builds for the simulator.
- **Feel check**: with Settings › Accessibility › Motion › Reduce Motion on, queue a message during a run: the card
  fades in place. Off: it rises from the composer.
- **Done when**: both behaviours are observed.
