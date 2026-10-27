#!/usr/bin/env bash
# Kill test for an answer cut off mid-stream. Starts a long answer in a chat conversation, kills the
# app once streamed text has been committed, relaunches it, and checks that Pi resent the request and
# finished the turn with one user message and a complete answer.
#
#   scripts/stream-kill.sh [--no-build]                                  # offline scripted model
#   PI_MODEL=deepseek/deepseek-flash scripts/stream-kill.sh --no-build   # a real provider (key in the Keychain)
source "$(dirname "$0")/lib.sh"

model=${PI_MODEL:-scripted/assistant}
if [[ "${1:-}" != --no-build ]]; then
	pi_build
	pi_install
fi

MODE_ERROR=streamkill-start-error.json
pi_launch streamkill-start "PI_MODEL=$model"
log "Waiting for the answer to stream ($model)"
deadline=$((SECONDS + 90))
until pi_fetch_current streamkill-start.jsonl "$OUT/streamkill-start.jsonl" &&
	python3 -c 'import json,sys; p=[json.loads(l) for l in open(sys.argv[1]) if "progress" in l]; sys.exit(0 if any(x["busy"] and x["chars"] >= 150 for x in p) else 1)' "$OUT/streamkill-start.jsonl"; do
	if pi_fetch_current "$MODE_ERROR" "$OUT/error.json"; then fail "start phase: $(cat "$OUT/error.json")"; fi
	((SECONDS < deadline)) || fail "no streamed text within 90 s"
	sleep 0.3
done
pi_terminate
sleep 1
pi_fetch streamkill-start.jsonl "$OUT/streamkill-start.jsonl"
python3 - "$OUT/streamkill-start.jsonl" <<'PY' || fail "the answer finished before the kill; nothing was cut off"
import json, sys
progress = [json.loads(l) for l in open(sys.argv[1]) if '"progress"' in l]
last = progress[-1]
print(f"  killed mid-stream with {last['chars']} characters committed")
sys.exit(0 if last["busy"] else 1)
PY

MODE_ERROR=streamkill-resume-error.json
pi_launch streamkill-resume "PI_MODEL=$model"
pi_wait_for streamkill-result.json 260
python3 - "$OUT/streamkill-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
for name, ok in sorted(result["checks"].items()):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
print(f"  entries: {' '.join(result['entries'])}; assistant stop reasons: {result['assistantStopReasons']}")
print(f"  answer: {result['answerChars']} chars, resumed in {result['resumeMs']:.0f} ms: {result['answerHead']!r}")
sys.exit(0 if result["pass"] else 1)
PY
log "Stream kill test passed on $TARGET ($model)"
