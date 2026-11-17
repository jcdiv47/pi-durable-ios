# pi-durable-ios

[![CI](https://github.com/jcdiv47/pi-durable-ios/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/jcdiv47/pi-durable-ios/actions/workflows/ci.yml)
![iOS](https://img.shields.io/badge/iOS-26%2B-000?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
[![last commit](https://img.shields.io/github/last-commit/jcdiv47/pi-durable-ios)](https://github.com/jcdiv47/pi-durable-ios/commits/main)
[![license](https://img.shields.io/github/license/jcdiv47/pi-durable-ios)](LICENSE)

A personal, sideloaded iPhone app that runs [`@earendil-works/pi-durable`](https://www.npmjs.com/package/@earendil-works/pi-durable)
in an embedded JavaScriptCore runtime.

## Build

Needs Xcode 27, [bun](https://bun.sh) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd js && bun install && bun run build && npx tsc -p .   # bundle + typecheck
xcodegen generate                                        # then open PiDurable.xcodeproj
```

[AGENTS.md](AGENTS.md) has the layout, the tests and the rules the code follows.

## License

[MIT](LICENSE)
