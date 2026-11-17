# pi-durable-ios

[![CI](https://github.com/jcdiv47/pi-durable-ios/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/jcdiv47/pi-durable-ios/actions/workflows/ci.yml)

A personal, sideloaded iPhone app that runs [`@earendil-works/pi-durable`](https://www.npmjs.com/package/@earendil-works/pi-durable)
in an embedded JavaScriptCore runtime.

## Build

Needs Xcode 27, [bun](https://bun.sh) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd js && bun install && bun run build && npx tsc -p .   # bundle + typecheck
xcodegen generate                                        # then open PiDurable.xcodeproj
```

[AGENTS.md](AGENTS.md) has the layout, the tests and the rules the code follows.
