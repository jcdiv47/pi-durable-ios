#!/usr/bin/env bash
# Shared helpers for driving PiApp from scripts. Targets the booted simulator by default,
# a specific simulator with PI_SIMULATOR=<udid>, or a physical iPhone with PI_DEVICE=<udid>.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID=dev.jcdiv47.pidurable
OUT="$ROOT/scripts/.out"
DERIVED="$ROOT/build/DerivedData"
mkdir -p "$OUT"

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

if [[ -n "${PI_DEVICE:-}" ]]; then
	TARGET=device
	UDID="$PI_DEVICE"
	PRODUCTS=Debug-iphoneos
	DESTINATION="id=$UDID"
else
	TARGET=simulator
	UDID="${PI_SIMULATOR:-$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; d=[x["udid"] for r in json.load(sys.stdin)["devices"].values() for x in r]; print(d[0] if d else "")')}"
	[[ -n "$UDID" ]] || fail "no booted simulator; boot one or set PI_SIMULATOR"
	PRODUCTS=Debug-iphonesimulator
	DESTINATION="platform=iOS Simulator,id=$UDID"
fi
APP="$DERIVED/Build/Products/$PRODUCTS/PiDurable.app"

pi_build() {
	log "Building PiApp for $TARGET $UDID"
	(cd "$ROOT" && xcodegen generate --quiet)
	xcodebuild -project "$ROOT/PiDurable.xcodeproj" -scheme PiApp -destination "$DESTINATION" \
		-derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet build
}

pi_install() {
	log "Installing"
	if [[ $TARGET == simulator ]]; then
		xcrun simctl install "$UDID" "$APP"
	else
		xcrun devicectl device install app --device "$UDID" "$APP" >/dev/null
	fi
}

# pi_launch <mode> [launch arguments...]. Simulator env vars pass through as SIMCTL_CHILD_*.
# Sets RUN_ID, which the app stamps on its reports (launch returns before the app clears old ones).
pi_launch() {
	local mode=$1
	shift
	RUN_ID="$mode-$(date +%s)-$RANDOM"
	log "Launching -PiMode $mode"
	if [[ $TARGET == simulator ]]; then
		xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -PiMode "$mode" -PiRunId "$RUN_ID" "$@" >/dev/null
	else
		xcrun devicectl device process launch --device "$UDID" --terminate-existing \
			--json-output "$OUT/launch.json" "$BUNDLE_ID" -PiMode "$mode" -PiRunId "$RUN_ID" "$@" >/dev/null
		python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["process"]["processIdentifier"])' "$OUT/launch.json" >"$OUT/pid"
	fi
}

# Kills the app the way iOS would: no chance to clean up.
pi_terminate() {
	log "Terminating"
	if [[ $TARGET == simulator ]]; then
		xcrun simctl terminate "$UDID" "$BUNDLE_ID"
	else
		xcrun devicectl device process terminate --device "$UDID" --pid "$(cat "$OUT/pid")" --kill >/dev/null
	fi
}

# pi_fetch <name> <destination>: copies Documents/m0/<name> out of the app container; fails if absent.
pi_fetch() {
	local name=$1 destination=$2
	rm -f "$destination"
	if [[ $TARGET == simulator ]]; then
		local container
		container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
		[[ -f "$container/Documents/m0/$name" ]] && cp "$container/Documents/m0/$name" "$destination"
	else
		xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
			--domain-identifier "$BUNDLE_ID" --source "Documents/m0/$name" --destination "$destination" >/dev/null 2>&1 &&
			[[ -f "$destination" ]]
	fi
}

# pi_fetch_current <name> <destination>: like pi_fetch, but only succeeds for this run's file.
pi_fetch_current() {
	pi_fetch "$1" "$2" && grep -q "$RUN_ID" "$2"
}

# pi_wait_for <name> <timeout seconds>: polls until this run's Documents/m0/<name> exists, copying it to $OUT/<name>.
pi_wait_for() {
	local name=$1 deadline=$((SECONDS + $2))
	until pi_fetch_current "$name" "$OUT/$name"; do
		if pi_fetch_current "${MODE_ERROR:-none}" "$OUT/error.json"; then fail "app reported: $(cat "$OUT/error.json")"; fi
		((SECONDS < deadline)) || fail "timed out waiting for $name"
		sleep 0.5
	done
}
