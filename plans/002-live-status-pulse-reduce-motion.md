# 002 — Stop the live status pulse under Reduce Motion

- **Status**: DONE
- **Commit**: 310e004
- **Severity**: MEDIUM
- **Category**: Accessibility / Cohesion
- **Estimated scope**: 1 file, ~2 lines

## Problem

`App/Sources/Chat/TranscriptViews.swift:287` — `LiveStatusRow` pulses its symbol forever while a run goes:

```swift
.symbolEffect(.pulse, isActive: approval == nil)
```

The list's working dot (`ChatRootView.swift:247`) stops its loop under Reduce Motion; this one does not.

## Target

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
...
.symbolEffect(.pulse, isActive: approval == nil && !reduceMotion)
```

The elapsed-time counter beside it still shows progress, so nothing is lost.

## Steps

1. Add the environment property to `LiveStatusRow`.
2. Change `isActive` to the target expression.

## Boundaries

- Do NOT change the symbol, colours or timer.

## Verification

- **Mechanical**: the PiApp scheme builds.
- **Feel check**: with Reduce Motion on, start a run: the status symbol is static, the timer still ticks.
- **Done when**: observed on the simulator.
