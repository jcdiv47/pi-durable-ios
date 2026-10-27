# ADR 0001: One surface catalog, validator and renderer, in Swift

Date: 2026-10-27. Status: accepted. Spec: 0001, "Generated native UI" and the risk "Spec schema drift".

## Context

The spec asks for one source of truth for the surface schema, "generated into both [TS and Swift] or
checked against shared fixtures", and lists vitest for spec validation shared with Swift through JSON
Schema fixtures. The UI tools run in JS; the renderer must be Swift (widgets cannot load JS).

## Decision

The catalog (components, props, families, slot limits, dial presets, data sources), the validator, the
renderer and `ImageRenderer` previews all live in PiUI. The JS tools (`js/src/app/surfaces.ts`) store specs in
Pi documents and call Swift through `hostCall` (`ui.catalog`, `ui.validate`, `ui.preview`, `ui.publish`,
`ui.values`, `ui.source`, `ui.unpublish`), the same pattern as the Apple tools. `list_components`' text is
generated from the catalog (`CatalogText`), so the model's instructions, the checks and the widget's
renderer cannot disagree, and there is no JSON Schema to keep in sync.

## Consequences

- No TS validator and no vitest suite. Validation is tested in Swift (`PiUITests`), and the tools end to end
  in macOS JSC against the real `SurfaceHost` (`PiRuntimeTests/SurfaceTests`).
- Validation is an async host call per tool call. It costs well under a millisecond plus a queue hop, against
  model calls of seconds.
- The widget validates nothing at render time: decoding is lenient and missing data draws a placeholder, so a
  spec published by an older app version still renders.
- Specs are not readable without Swift. Nothing in JS needs to understand them beyond JSON Patch.
