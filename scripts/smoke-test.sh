#!/usr/bin/env bash
# End-to-end smoke test for the vdownloader stack: submits a real download
# job through the same path a user would (web -> RabbitMQ -> worker -> file)
# and verifies the result, including the video codec. Meant to be run
# against a freshly started `docker compose up` stack before it's deployed
# to (or promoted on) a server.
#
# Usage:
#   ./scripts/smoke-test.sh
#   WEB_URL=http://myserver:8082 WORKER_URL=http://myserver:8080 ./scripts/smoke-test.sh
#
# Exits non-zero on the first failed check. Note: the downloaded file is
# fetched to a local temp file and removed afterward, but the copy the
# worker itself keeps under OUT_DIR is not deleted (no delete endpoint
# exists) - each run leaves one small test file behind on the target.
set -euo pipefail

WEB_URL="${WEB_URL:-http://localhost:8082}"
WORKER_URL="${WORKER_URL:-http://localhost:8080}"
# Big Buck Bunny, official Blender Foundation upload (Creative Commons,
# extremely unlikely to ever be removed) with a full normal resolution
# ladder (360p..2160p) - unlike e.g. very old/low-res archival videos, whose
# max height can sit below the smallest standard tier (360p) and so never
# offer a selectable video_heights entry at all.
TEST_URL="${TEST_URL:-https://www.youtube.com/watch?v=aqz-KE-bpKQ}"
POLL_TIMEOUT="${POLL_TIMEOUT:-240}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Crude single-line JSON field extractor so this script has no dependency
# beyond curl/bash (no jq requirement). Always exits 0, even on no match
# (returning an empty string) - under `set -e -o pipefail`, letting grep's
# no-match exit status propagate out of a command substitution like
# `x=$(json_field ...)` would silently kill the whole script right there,
# before the caller's own "$x is empty" check ever gets to print a real
# error message.
json_field() {
	local json="$1" field="$2"
	echo "$json" | grep -oE "\"$field\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9.]+)" |
		head -1 | sed -E "s/^\"$field\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"\$//"
	return 0
}

echo "== 1. containers up (skipped if docker compose isn't available for this target) =="
if command -v docker >/dev/null 2>&1 && docker compose ps >/dev/null 2>&1; then
	for svc in rabbitmq worker telegram web; do
		docker compose ps --status running --services 2>/dev/null | grep -qx "$svc" ||
			fail "service '$svc' is not running (docker compose ps)"
	done
	pass "all 4 containers running"
else
	echo "SKIP: docker compose not usable from here (fine when testing a remote server)"
fi

echo "== 2. rabbitmq queues exist (video.jobs, video.completed) =="
if command -v docker >/dev/null 2>&1 && docker compose ps >/dev/null 2>&1; then
	queues=$(MSYS_NO_PATHCONV=1 docker compose exec -T rabbitmq \
		rabbitmqctl list_queues --quiet --formatter plain name 2>/dev/null || true)
	for q in video.jobs video.completed; do
		echo "$queues" | grep -qx "$q" ||
			fail "rabbitmq queue '$q' does not exist yet (a service may not have connected)"
	done
	pass "required queues exist"
else
	echo "SKIP: same as above"
fi

echo "== 3. worker responds with real format info (GET /api/formats) =="
formats_resp=$(curl -sf -G --data-urlencode "url=$TEST_URL" "$WORKER_URL/api/formats") ||
	fail "GET $WORKER_URL/api/formats failed"
title=$(json_field "$formats_resp" title)
[ -n "$title" ] || fail "formats response has no title: $formats_resp"
# video_heights is descending (highest first) - pick the lowest offered tier
# so the smoke test's own download is as fast as possible; the code path
# exercised is identical regardless of which tier is picked.
height=$(echo "$formats_resp" | grep -oE '"video_heights":\[[0-9,]*\]' | grep -oE '[0-9]+' | tail -1)
[ -n "$height" ] || fail "no usable video_heights in response: $formats_resp"
pass "title=\"$title\", picked lowest offered height=$height"

echo "== 4. submit a real job end-to-end (web -> RabbitMQ -> worker) =="
job_resp=$(curl -sf -X POST "$WEB_URL/api/jobs" -H 'Content-Type: application/json' \
	-d "{\"url\":\"$TEST_URL\",\"title\":\"$title\",\"kind\":\"video\",\"height\":$height,\"with_audio\":true}") ||
	fail "POST $WEB_URL/api/jobs failed"
file_id=$(json_field "$job_resp" file_id)
[ -n "$file_id" ] || fail "no file_id in job response: $job_resp"
echo "submitted, file_id=$file_id"

echo "== 5. poll until the job leaves 'pending' (timeout ${POLL_TIMEOUT}s) =="
# Also implicitly checks that the job shows up at all within a few seconds -
# i.e. that the worker's consumer actually received and persisted the
# published job rather than it being silently dropped.
deadline=$((SECONDS + POLL_TIMEOUT))
status=""
while [ "$SECONDS" -lt "$deadline" ]; do
	job=$(curl -sf "$WORKER_URL/api/jobs/$file_id" 2>/dev/null || true)
	status=$(json_field "$job" status)
	[ "$status" = "ready" ] && break
	if [ "$status" = "failed" ]; then
		fail "job failed: $(json_field "$job" error)"
	fi
	sleep 3
done
[ "$status" = "ready" ] || fail "job did not become ready within ${POLL_TIMEOUT}s (last status: '$status')"
pass "job ready"

echo "== 6. download the finished file =="
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
curl -sf "$WORKER_URL/files/$file_id" -o "$tmpfile" || fail "GET $WORKER_URL/files/$file_id failed"
size=$(wc -c <"$tmpfile" | tr -d ' ')
[ "$size" -gt 1000 ] || fail "downloaded file is suspiciously small ($size bytes)"
pass "downloaded $size bytes"

echo "== 7. video codec is H.264 (catches codec-not-actually-transcoded regressions) =="
if command -v ffprobe >/dev/null 2>&1; then
	codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$tmpfile" 2>/dev/null || true)
	[ "$codec" = "h264" ] || fail "video codec is '$codec', want h264"
	pass "codec is h264"
else
	echo "SKIP: ffprobe not found locally"
fi

echo
echo "ALL CHECKS PASSED"
