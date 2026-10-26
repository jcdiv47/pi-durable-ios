#!/usr/bin/env bash
# M0 kill test. Starts a turn whose model calls a replay-safe tool (slow_lookup) and a
# non-replay-safe tool (send_message), kills the app while both run, relaunches it, and checks
# that resume() finishes the turn: slow_lookup reruns, send_message is reported interrupted.
#
#   scripts/kill-test.sh [--no-build]            # booted simulator
#   PI_DEVICE=<udid> scripts/kill-test.sh        # physical iPhone (unlocked)
source "$(dirname "$0")/lib.sh"

if [[ "${1:-}" != --no-build ]]; then
	pi_build
	pi_install
fi

MODE_ERROR=killtest-start-error.json
pi_launch killtest-start
log "Waiting for both tools to start"
deadline=$((SECONDS + 60))
until pi_fetch killtest-start.jsonl "$OUT/start.jsonl" && [[ $(grep -c '"event":"start"' "$OUT/start.jsonl") -ge 2 ]]; do
	if pi_fetch "$MODE_ERROR" "$OUT/error.json"; then fail "start phase: $(cat "$OUT/error.json")"; fi
	((SECONDS < deadline)) || fail "tools did not start within 60 s"
	sleep 0.5
done
sleep 1 # both tools are now mid-call (they sleep for 120 s)
pi_terminate
sleep 1
pi_fetch killtest-start.jsonl "$OUT/start.jsonl"
if grep -q '"event":"end"' "$OUT/start.jsonl"; then fail "a tool finished before the kill; the test did not interrupt anything"; fi
log "Killed mid-call: $(grep -c '"event":"start"' "$OUT/start.jsonl") tools started, none finished"

MODE_ERROR=killtest-resume-error.json
pi_launch killtest-resume
pi_wait_for killtest-result.json 60
python3 - "$OUT/killtest-result.json" <<'EOF'
import json, sys
result = json.load(open(sys.argv[1]))
for name, ok in sorted(result["checks"].items()):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
settle = result["settle"]
print(f"  entries: {' '.join(settle['entryKinds'])}")
print(f"  answer: {settle['answer']}")
sys.exit(0 if result["pass"] else 1)
EOF
log "Kill test passed on $TARGET"
