#!/usr/bin/env bash
# Triggers a Coolify deployment through the Coolify API and, optionally,
# waits for it to finish. All inputs come from environment variables (see
# action.yml). Requires bash 3.2+, curl and jq.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { echo "$*"; }
warn()  { echo "::warning::$*"; }
fail()  { echo "::error::$*"; exit 1; }
group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Turns "a, b\nc" into "a,b,c".
to_csv() {
  printf '%s' "${1:-}" | tr ',\n\r\t' '    ' | xargs | tr ' ' ','
}

set_output() {
  local name="$1" value="$2"
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  local delimiter
  delimiter="EOF_$(date +%s)_$RANDOM$RANDOM"
  {
    echo "${name}<<${delimiter}"
    echo "${value}"
    echo "${delimiter}"
  } >> "$GITHUB_OUTPUT"
}

summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  echo "$*" >> "$GITHUB_STEP_SUMMARY"
}

command -v curl >/dev/null 2>&1 || fail "curl is required but was not found on the runner."
command -v jq   >/dev/null 2>&1 || fail "jq is required but was not found on the runner."

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
BODY_FILE="$WORK_DIR/body.json"

HTTP_STATUS=""
BODY=""

# api METHOD PATH [QUERY_STRING]
# Sets HTTP_STATUS ("000" when the server could not be reached) and BODY.
api() {
  local method="$1" path="$2" query="${3:-}"
  local url="${API_URL}${path}"
  [ -n "$query" ] && url="${url}?${query}"
  : > "$BODY_FILE"
  HTTP_STATUS="$(curl -sS -X "$method" \
    --proto '=http,https' --connect-timeout 10 --max-time 60 \
    -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
    -H "Accept: application/json" \
    -o "$BODY_FILE" -w '%{http_code}' \
    "$url" 2>"$WORK_DIR/curl.err")" || HTTP_STATUS="000"
  BODY="$(cat "$BODY_FILE")"
}

# Prints the "message" of an error body, or the raw body.
api_message() {
  local msg
  msg="$(printf '%s' "$BODY" | jq -r '
    if type == "object" and has("message") then
      (.message | if type == "array" then join("; ") else tostring end)
    else empty end' 2>/dev/null || true)"
  if [ -n "$msg" ]; then printf '%s' "$msg"; else printf '%s' "$BODY" | head -c 500; fi
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

COOLIFY_URL="$(printf '%s' "${COOLIFY_URL:-}" | xargs)"
WEBHOOK="$(printf '%s' "${DEPLOY_WEBHOOK:-}" | xargs)"
COOLIFY_TOKEN="${COOLIFY_TOKEN:-}"
UUIDS="$(to_csv "${DEPLOY_UUID:-}")"
TAGS="$(to_csv "${DEPLOY_TAG:-}")"
PR="$(printf '%s' "${DEPLOY_PR:-}" | xargs)"
CANCEL_PREVIOUS="$(printf '%s' "${DEPLOY_CANCEL_PREVIOUS:-none}" | xargs | tr '[:upper:]' '[:lower:]')"
TIMEOUT="${DEPLOY_TIMEOUT:-900}"
INTERVAL="${DEPLOY_INTERVAL:-10}"
CONNECT_TIMEOUT="${DEPLOY_CONNECT_TIMEOUT:-120}"
SHOW_LOGS="$(printf '%s' "${DEPLOY_SHOW_LOGS:-on-failure}" | xargs | tr '[:upper:]' '[:lower:]')"
FORCE="false"; is_true "${DEPLOY_FORCE:-false}" && FORCE="true"
WAIT="false";  is_true "${DEPLOY_WAIT:-true}"   && WAIT="true"

[ -n "$COOLIFY_TOKEN" ] || fail "Input 'coolify-token' is required."
echo "::add-mask::${COOLIFY_TOKEN}"

# The deploy webhook shown in Coolify (https://host/api/v1/deploy?uuid=...&force=false)
# carries both the instance URL and the resource to deploy.
WEBHOOK_QUERY=""
if [ -n "$WEBHOOK" ]; then
  echo "::add-mask::${WEBHOOK}"
  case "$WEBHOOK" in
    http://*/api/v1/deploy\?*|https://*/api/v1/deploy\?*) ;;
    *) fail "Input 'webhook' must be a Coolify deploy webhook URL such as https://coolify.example.ts.net/api/v1/deploy?uuid=..." ;;
  esac
  if [ -n "$UUIDS" ] || [ -n "$TAGS" ]; then
    fail "Input 'webhook' cannot be used together with 'uuid' or 'tag'."
  fi
  WEBHOOK_QUERY="${WEBHOOK#*\?}"
  WEBHOOK_BASE="${WEBHOOK%%/api/v1/deploy\?*}"
  if [ -n "$COOLIFY_URL" ] && [ "${COOLIFY_URL%/}" != "$WEBHOOK_BASE" ]; then
    warn "Input 'coolify-url' is ignored because 'webhook' is set."
  fi
  COOLIFY_URL="$WEBHOOK_BASE"
elif [ -z "$UUIDS" ] && [ -z "$TAGS" ]; then
  fail "Set the 'uuid', 'tag' or 'webhook' input."
fi
[ -n "$COOLIFY_URL" ] || fail "Input 'coolify-url' is required (unless 'webhook' is set)."
if [ -n "$UUIDS" ] && [ -n "$TAGS" ]; then
  fail "Inputs 'uuid' and 'tag' cannot be used together."
fi
if [ -n "$PR" ]; then
  is_uint "$PR" || fail "Input 'pr' must be a pull request number, got '$PR'."
  [ -z "$TAGS" ] || fail "Inputs 'pr' and 'tag' cannot be used together."
fi
case "$CANCEL_PREVIOUS" in
  none|queued|building) ;;
  *) fail "Input 'cancel-previous' must be one of: none, queued, building." ;;
esac
case "$SHOW_LOGS" in
  on-failure|always|never) ;;
  *) fail "Input 'show-logs' must be one of: on-failure, always, never." ;;
esac
is_uint "$TIMEOUT"         || fail "Input 'timeout' must be a number of seconds."
is_uint "$INTERVAL"        || fail "Input 'interval' must be a number of seconds."
is_uint "$CONNECT_TIMEOUT" || fail "Input 'connect-timeout' must be a number of seconds."
[ "$INTERVAL" -ge 1 ] || INTERVAL=1

# Accept "https://host", "https://host/" and "https://host/api/v1".
BASE_URL="${COOLIFY_URL%/}"
BASE_URL="${BASE_URL%/api/v1}"
BASE_URL="${BASE_URL%/api}"
BASE_URL="${BASE_URL%/}"
case "$BASE_URL" in
  http://*|https://*) ;;
  *) fail "Input 'coolify-url' must start with http:// or https://, got '$COOLIFY_URL'." ;;
esac
API_URL="${BASE_URL}/api/v1"

# ---------------------------------------------------------------------------
# 1. Wait until Coolify is reachable (tailnet peers can take a few seconds
#    to learn about the new runner node).
# ---------------------------------------------------------------------------

is_dns_error() { grep -q "Could not resolve host" "$WORK_DIR/curl.err" 2>/dev/null; }

# Tailscale configures MagicDNS in the background, shortly after `tailscale up`
# returns. A *.ts.net lookup made before that goes to public DNS, gets
# NXDOMAIN, and systemd-resolved keeps serving that cached answer even once
# MagicDNS is ready. Flushing the cache makes the next attempt ask again.
flush_dns_cache() {
  command -v resolvectl >/dev/null 2>&1 || return 0
  sudo -n resolvectl flush-caches >/dev/null 2>&1 || resolvectl flush-caches >/dev/null 2>&1 || true
}

print_dns_diagnostics() {
  group "DNS diagnostics"
  if command -v resolvectl >/dev/null 2>&1; then
    echo "\$ resolvectl status"; resolvectl status 2>&1 || true
  fi
  if command -v tailscale >/dev/null 2>&1; then
    echo "\$ tailscale dns status"; tailscale dns status 2>&1 || true
  fi
  endgroup
}

info "Checking that Coolify is reachable at ${BASE_URL}..."
deadline=$(( $(date +%s) + CONNECT_TIMEOUT ))
while :; do
  api GET "/health"
  [ "$HTTP_STATUS" != "000" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    cat "$WORK_DIR/curl.err" >&2 || true
    if is_dns_error; then
      print_dns_diagnostics
      fail "Could not resolve the Coolify host of ${BASE_URL} after ${CONNECT_TIMEOUT}s. If it is a MagicDNS name (or a CNAME to one), check that MagicDNS is enabled for your tailnet, or use the Tailscale IP instead. See the DNS diagnostics above."
    fi
    fail "Could not reach Coolify at ${BASE_URL} after ${CONNECT_TIMEOUT}s. Check that the URL is correct, that the runner joined your tailnet and that your Tailscale ACLs let the runner's tags reach the Coolify host and port."
  fi
  is_dns_error && flush_dns_cache
  sleep 3
done
info "Coolify is reachable (HTTP ${HTTP_STATUS})."

# ---------------------------------------------------------------------------
# 2. Trigger the deployment.
# ---------------------------------------------------------------------------

# With a webhook, its own parameters come first and the action inputs are only
# appended when set (Coolify keeps the last value of a repeated parameter).
if [ -n "$WEBHOOK" ]; then
  [ "$FORCE" = "true" ] || FORCE=""
fi
QUERY="$(jq -rn \
  --arg base "$WEBHOOK_QUERY" \
  --arg uuid "$UUIDS" --arg tag "$TAGS" --arg force "$FORCE" \
  --arg pr "$PR" --arg cancel "$CANCEL_PREVIOUS" '
  [ ["uuid", $uuid], ["tag", $tag], ["force", $force], ["pr", $pr],
    ["cancel_previous", (if $cancel == "none" then "" else $cancel end)] ]
  | map(select(.[1] != "") | "\(.[0])=\(.[1] | @uri)")
  | [$base | select(. != "")] + .
  | join("&")')"

if [ -n "$WEBHOOK" ]; then
  info "Deploying with the Coolify deploy webhook${FORCE:+ (force=true)}${PR:+ (pr=$PR)}..."
elif [ -n "$UUIDS" ]; then
  info "Deploying resource(s) ${UUIDS} (force=${FORCE}${PR:+, pr=$PR})..."
else
  info "Deploying resources tagged ${TAGS} (force=${FORCE})..."
fi

# Recent Coolify versions only accept POST; older ones only accept GET.
api POST "/deploy" "$QUERY"
if [ "$HTTP_STATUS" = "405" ]; then
  info "POST /deploy is not supported by this Coolify version, retrying with GET."
  api GET "/deploy" "$QUERY"
fi

case "$HTTP_STATUS" in
  200) ;;
  000)
    cat "$WORK_DIR/curl.err" >&2 || true
    fail "Lost the connection to Coolify while triggering the deployment." ;;
  401|403)
    message="$(api_message)"
    case "$message" in
      *"API is disabled"*)
        hint="Enable the API in your Coolify settings." ;;
      *"not allowed to access the API"*)
        hint="Coolify only accepts API calls from its allowed IPs. Add the runner's Tailscale address (or the tailnet range 100.64.0.0/10) to the API allowlist in your Coolify settings." ;;
      *"Missing required permissions"*)
        hint="Create an API token with the 'deploy' permission (and 'read' to wait for the deployment)." ;;
      *)
        hint="Check that the API token is valid and belongs to the team that owns the resource." ;;
    esac
    fail "Coolify rejected the request (HTTP ${HTTP_STATUS}): ${message}. ${hint}" ;;
  404)
    fail "Nothing to deploy (HTTP 404): $(api_message). Check the UUID(s) or tag(s) and that the token belongs to the right team." ;;
  429)
    fail "The Coolify deployment queue is full (HTTP 429): $(api_message)." ;;
  *)
    fail "Coolify returned HTTP ${HTTP_STATUS}: $(api_message)" ;;
esac

RESPONSE="$BODY"
set_output response "$RESPONSE"

printf '%s' "$RESPONSE" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || fail "Unexpected response from Coolify: $(printf '%s' "$RESPONSE" | head -c 500)"

# Messages returned by Coolify (one per resource or per tag).
printf '%s' "$RESPONSE" | jq -r '
  ((.deployments // [])[] | "  - \(.resource_uuid // "?"): \(.message // "queued")"),
  ((.message // empty) | if type == "array" then .[] else . end | "  - \(.)")
' | while IFS= read -r line; do info "$line"; done

# Coolify answers 200 even when one of the resources could not be deployed.
ERRORS="$(printf '%s' "$RESPONSE" | jq -r '
  [ (.deployments // [])[] | select((.deployment_uuid // "") == "") | .message // "" ]
  | map(select(test("^(Unauthorized|Missing required permissions)|not found|can only be used|must be"; "i")))
  | .[]')"
if [ -n "$ERRORS" ]; then
  while IFS= read -r line; do echo "::error::${line}"; done <<< "$ERRORS"
  fail "Coolify could not deploy every requested resource."
fi

DEPLOYMENT_UUIDS="$(printf '%s' "$RESPONSE" | jq -r '
  [ (.deployments // [])[]?.deployment_uuid, (.details // [])[]?.deployment_uuid ]
  | map(select(. != null and . != ""))
  | reduce .[] as $id ([]; if index([$id]) then . else . + [$id] end)
  | join(",")')"
set_output deployment-uuids "$DEPLOYMENT_UUIDS"

if [ -z "$DEPLOYMENT_UUIDS" ]; then
  # Services and databases are started directly and have no deployment to follow.
  info "Coolify did not return any application deployment to follow (services and databases are started directly)."
  set_output status "finished"
  summary "### Coolify deployment"
  summary ""
  summary "Coolify accepted the request. No application deployment to follow."
  exit 0
fi

info "Queued deployment(s): ${DEPLOYMENT_UUIDS}"

if [ "$WAIT" != "true" ]; then
  set_output status "queued"
  summary "### Coolify deployment"
  summary ""
  summary "Queued deployment(s): \`${DEPLOYMENT_UUIDS//,/\`, \`}\`"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Wait for every deployment to reach a final status.
# ---------------------------------------------------------------------------

IFS=',' read -r -a IDS <<< "$DEPLOYMENT_UUIDS"
STATUSES=(); NAMES=(); LINKS=()
for i in "${!IDS[@]}"; do STATUSES[i]="queued"; NAMES[i]=""; LINKS[i]=""; done

is_final() {
  case "$1" in finished|failed|cancelled-by-user|cancelled|skipped|error) return 0 ;; *) return 1 ;; esac
}

print_logs() {
  local file="$1" title="$2"
  [ -s "$file" ] || return 0
  group "$title"
  jq -r '
    (.logs // "[]")
    | (if type == "string" then (try fromjson catch [{"output": .}]) else . end)
    | if type == "array" then .[] else {output: tostring} end
    | select((.hidden // false) | not)
    | .output // empty' "$file" 2>/dev/null || cat "$file"
  endgroup
}

info "Waiting up to ${TIMEOUT}s for the deployment(s) to finish..."
deadline=$(( $(date +%s) + TIMEOUT ))
consecutive_errors=0

while :; do
  pending=0
  for i in "${!IDS[@]}"; do
    is_final "${STATUSES[$i]}" && continue
    id="${IDS[$i]}"
    api GET "/deployments/${id}"
    if [ "$HTTP_STATUS" != "200" ]; then
      consecutive_errors=$((consecutive_errors + 1))
      warn "Could not get the status of deployment ${id} (HTTP ${HTTP_STATUS}): $(api_message)"
      if [ "$HTTP_STATUS" = "401" ] || [ "$HTTP_STATUS" = "403" ]; then
        fail "The API token cannot read deployments. Give it the 'read' permission, or set 'wait' to false."
      fi
      [ "$consecutive_errors" -lt 10 ] || fail "Too many errors while checking the deployment status."
      pending=$((pending + 1))
      continue
    fi
    consecutive_errors=0
    printf '%s' "$BODY" > "$WORK_DIR/deployment-${i}.json"
    status="$(printf '%s' "$BODY" | jq -r '.status // "unknown"')"
    NAMES[i]="$(printf '%s' "$BODY" | jq -r '.application_name // ""')"
    url_path="$(printf '%s' "$BODY" | jq -r '.deployment_url // ""')"
    if [ -n "$url_path" ]; then
      case "$url_path" in
        http://*|https://*) LINKS[i]="$url_path" ;;
        *) LINKS[i]="${BASE_URL}/${url_path#/}" ;;
      esac
    fi
    if [ "$status" != "${STATUSES[$i]}" ]; then
      info "[$(date -u +%H:%M:%S)] ${NAMES[$i]:-$id}: ${status}"
      STATUSES[i]="$status"
    fi
    is_final "$status" || pending=$((pending + 1))
  done

  [ "$pending" -eq 0 ] && break
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep "$INTERVAL"
done

# ---------------------------------------------------------------------------
# 4. Report.
# ---------------------------------------------------------------------------

overall="finished"
summary "### Coolify deployment"
summary ""
summary "| Application | Deployment | Status |"
summary "| --- | --- | --- |"
for i in "${!IDS[@]}"; do
  id="${IDS[$i]}"; status="${STATUSES[$i]}"; name="${NAMES[$i]:-$id}"
  case "$status" in
    finished|skipped) ok="true" ;;
    *) ok="false" ;;
  esac

  if [ "$SHOW_LOGS" = "always" ] || { [ "$SHOW_LOGS" = "on-failure" ] && [ "$ok" = "false" ]; }; then
    print_logs "$WORK_DIR/deployment-${i}.json" "Coolify logs: ${name} (${id})"
  fi

  if [ -n "${LINKS[$i]}" ]; then
    summary "| ${name} | [\`${id}\`](${LINKS[$i]}) | ${status} |"
  else
    summary "| ${name} | \`${id}\` | ${status} |"
  fi

  case "$status" in
    finished) info "✔ ${name}: deployment finished.${LINKS[$i]:+ ${LINKS[$i]}}" ;;
    skipped)  warn "${name}: Coolify skipped the deployment." ;;
    *)
      if is_final "$status"; then
        echo "::error::${name}: deployment ${status}.${LINKS[$i]:+ ${LINKS[$i]}}"
        overall="failed"
      else
        echo "::error::${name}: deployment still '${status}' after ${TIMEOUT}s.${LINKS[$i]:+ ${LINKS[$i]}}"
        [ "$overall" = "failed" ] || overall="timeout"
      fi
      ;;
  esac
done

set_output status "$overall"

case "$overall" in
  finished) info "All deployments finished successfully." ;;
  timeout)  fail "Timed out after ${TIMEOUT}s waiting for the deployment(s). They may still be running in Coolify." ;;
  *)        fail "At least one deployment did not succeed." ;;
esac

