#!/usr/bin/env bash
# Runs one headless M0 mode of PiApp and prints its report from Documents/m0/.
#
#   scripts/m0-check.sh conformance  [--no-build]   # storage conformance + facade + polyfills, in the app's JSC
#   scripts/m0-check.sh capabilities [--no-build]   # App Group, Keychain, HealthKit, Live Activities, BG tasks
#   scripts/m0-check.sh measure      [--no-build]   # bundle size, cold start, memory, time per token
#   scripts/m0-check.sh stream       [--no-build]   # one streamed answer in the chat view (needs a key: push-key.sh)
#
# Same targets as kill-test.sh (PI_DEVICE=<udid> for an iPhone). For JIT-off numbers on the
# simulator: SIMCTL_CHILD_JSC_useJIT=false scripts/m0-check.sh measure
source "$(dirname "$0")/lib.sh"

mode=${1:?usage: m0-check.sh conformance|capabilities|measure|stream [--no-build]}
launch_environment=()
case $mode in
conformance | capabilities) report=$mode.json timeout=120 ;;
measure) report=metrics.json timeout=300 ;;
stream)
	report=stream.json timeout=300
	launch_environment=("PI_PROMPT=In about 150 words, explain why an AI agent running on a phone needs to survive being killed.")
	;;
*) fail "unknown mode $mode" ;;
esac

if [[ "${2:-}" != --no-build ]]; then
	pi_build
	pi_install
fi

MODE_ERROR=$mode-error.json
pi_launch "$mode" ${launch_environment[@]+"${launch_environment[@]}"} # the app deletes its previous report first
pi_wait_for "$report" "$timeout"
cat "$OUT/$report"
echo
if [[ $mode == conformance ]]; then
	python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["pass"] else 1)' "$OUT/$report" || fail "conformance failed"
fi
