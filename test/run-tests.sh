#!/usr/bin/env bash
# Runs scripts/deploy.sh against test/mock_coolify.py and checks the results.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8787}"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

start_mock() {
  local port="$1"; shift
  env "$@" python3 "$ROOT/test/mock_coolify.py" "$port" 2>"$TMP/mock-$port.log" &
  PIDS+=("$!")
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/api/health" && return 0
    sleep 0.1
  done
  echo "mock server on port $port did not start" >&2; exit 1
}

start_mock "$PORT"
start_mock "$((PORT + 1))" MOCK_GET_ONLY=1

failures=0

# run NAME EXPECTED_EXIT EXPECTED_STATUS_OUTPUT [VAR=value ...]
run() {
  local name="$1" want_exit="$2" want_status="$3"; shift 3
  local out="$TMP/out" summary="$TMP/summary" log="$TMP/log"
  : > "$out"; : > "$summary"
  env -i PATH="$PATH" HOME="$HOME" \
    GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" \
    COOLIFY_URL="http://127.0.0.1:$PORT" COOLIFY_TOKEN="test-token" \
    DEPLOY_INTERVAL=1 DEPLOY_TIMEOUT=20 DEPLOY_CONNECT_TIMEOUT=5 \
    "$@" bash "$ROOT/scripts/deploy.sh" > "$log" 2>&1
  local code=$?
  local status
  status="$(awk '/^status<</{getline; print; exit}' "$out")"
  if [ "$code" -eq "$want_exit" ] && [ "$status" = "$want_status" ]; then
    echo "PASS  $name"
  else
    echo "FAIL  $name (exit $code, want $want_exit; status '$status', want '$want_status')"
    sed 's/^/      | /' "$log"
    failures=$((failures + 1))
  fi
  cp "$log" "$TMP/last.log"
}

expect_log() {
  if grep -qF -- "$1" "$TMP/last.log"; then echo "PASS    log contains: $1"
  else echo "FAIL    log is missing: $1"; failures=$((failures + 1)); fi
}
refute_log() {
  if grep -qF -- "$1" "$TMP/last.log"; then echo "FAIL    log should not contain: $1"; failures=$((failures + 1))
  else echo "PASS    log does not contain: $1"; fi
}

run "deploy one app and wait"            0 finished DEPLOY_UUID=app-ok
refute_log "Building app-ok"
run "trailing /api/v1 in the URL"        0 finished DEPLOY_UUID=app-ok COOLIFY_URL="http://127.0.0.1:$PORT/api/v1/"
run "several apps, newline separated"    0 finished DEPLOY_UUID=$'app-ok\napp-ok'
run "deploy by tag"                      0 finished DEPLOY_TAG=web
run "failed deployment prints logs"      1 failed   DEPLOY_UUID=app-fail
expect_log "Build failed: exit code 1"
refute_log "secret internal command"
run "show-logs=never"                    1 failed   DEPLOY_UUID=app-fail DEPLOY_SHOW_LOGS=never
refute_log "Build failed: exit code 1"
run "one ok and one failed"              1 failed   DEPLOY_UUID=app-ok,app-fail
run "timeout"                            1 timeout  DEPLOY_UUID=app-slow DEPLOY_TIMEOUT=3
run "no wait"                            0 queued   DEPLOY_UUID=app-slow DEPLOY_WAIT=false
run "service, nothing to follow"         0 finished DEPLOY_UUID=service-ok
run "unauthorized resource"              1 ""       DEPLOY_UUID=unauthorized
expect_log "Unauthorized to deploy this application."
run "unknown uuid"                       1 ""       DEPLOY_UUID=missing
expect_log "Nothing to deploy (HTTP 404)"
run "bad token"                          1 ""       DEPLOY_UUID=app-ok COOLIFY_TOKEN=wrong
expect_log "rejected the request (HTTP 401)"
run "old Coolify (GET only)"             0 finished DEPLOY_UUID=app-ok COOLIFY_URL="http://127.0.0.1:$((PORT + 1))"
expect_log "retrying with GET"
run "webhook URL"                        0 finished DEPLOY_WEBHOOK="http://127.0.0.1:$PORT/api/v1/deploy?uuid=app-ok&force=false" COOLIFY_URL=
run "webhook, force overrides"           0 finished DEPLOY_WEBHOOK="http://127.0.0.1:$PORT/api/v1/deploy?uuid=app-ok&force=false" DEPLOY_FORCE=true
expect_log "force=true"
run "webhook of a failing app"           1 failed   DEPLOY_WEBHOOK="http://127.0.0.1:$PORT/api/v1/deploy?uuid=app-fail"
run "webhook and uuid together"          1 ""       DEPLOY_WEBHOOK="http://127.0.0.1:$PORT/api/v1/deploy?uuid=app-ok" DEPLOY_UUID=app-ok
run "invalid webhook URL"                1 ""       DEPLOY_WEBHOOK="http://127.0.0.1:$PORT/api/v1/applications"
run "missing uuid and tag"               1 ""
run "uuid and tag together"              1 ""       DEPLOY_UUID=app-ok DEPLOY_TAG=web
run "unreachable Coolify"                1 ""       DEPLOY_UUID=app-ok COOLIFY_URL="http://127.0.0.1:1" DEPLOY_CONNECT_TIMEOUT=2
expect_log "Could not reach Coolify"

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed."; exit 1; fi
echo "All checks passed."
