#!/usr/bin/env bash
# Upload config/mutelist.yaml to the running Prowler server.
#
# The server stores mutelists as a "processor" (one per tenant), so this
# creates the processor on first run and updates it thereafter.
#
#   ./scripts/apply-mutelist.sh                 # prompts for your Prowler login
#   PROWLER_EMAIL=you@example.com ./scripts/apply-mutelist.sh
#
# Your Prowler password is read interactively and never stored or echoed. It is
# the local account you created at http://localhost:3000 — unrelated to AWS.
set -euo pipefail

cd "$(dirname "$0")/.."

API="${PROWLER_API:-http://localhost:8080/api/v1}"
FILE="${1:-config/mutelist.yaml}"

[[ -f "$FILE" ]] || { echo "error: $FILE not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 is required" >&2; exit 1; }

curl -sfL -o /dev/null "${API%/api/v1}/api/v1/docs" \
  || { echo "error: Prowler API not reachable at ${API} — is the stack up? (make up)" >&2; exit 1; }

if [[ ! -t 0 && -z "${PROWLER_PASSWORD:-}" ]]; then
  echo "error: this script prompts for a password, so it needs a terminal." >&2
  echo "       Run it directly (make mutelist), not through a pipe or from a" >&2
  echo "       CI job. For automation, set PROWLER_EMAIL and PROWLER_PASSWORD." >&2
  exit 1
fi

email="${PROWLER_EMAIL:-}"
if [[ -z "$email" ]]; then
  read -r -p "Prowler email: " email || {
    echo "error: no email given" >&2; exit 1; }
fi
[[ -n "$email" ]] || { echo "error: email cannot be empty" >&2; exit 1; }

# -s: no echo. The password never reaches the process list or the shell history.
password="${PROWLER_PASSWORD:-}"
if [[ -z "$password" ]]; then
  read -r -s -p "Prowler password: " password || {
    echo >&2; echo "error: no password given" >&2; exit 1; }
  echo
fi
[[ -n "$password" ]] || { echo "error: password cannot be empty" >&2; exit 1; }

echo "==> Authenticating"

# Deliberately NOT `curl -f`: with -f the body is discarded and the script dies
# on curl's raw exit code (22) before it can explain anything. Capture the body
# and the status separately so every failure gets a readable message.
auth_body=$(jq -n --arg e "$email" --arg p "$password" '{
  data: { type: "tokens", attributes: { email: $e, password: $p } }
}' | curl -sS -X POST "${API}/tokens" \
      -H "Content-Type: application/vnd.api+json" \
      -H "Accept: application/vnd.api+json" \
      -w '\n%{http_code}' \
      --data-binary @- 2>/dev/null) || {
  echo "error: could not reach ${API}/tokens" >&2
  exit 1
}

unset password

auth_code=${auth_body##*$'\n'}
auth_json=${auth_body%$'\n'*}

case "$auth_code" in
  200|201)
    ;;
  400|401)
    echo "error: authentication failed (HTTP ${auth_code})." >&2
    echo "       That email/password is not a valid Prowler login. This is the" >&2
    echo "       local account created at http://localhost:3000 — not your AWS" >&2
    echo "       credentials, and not your GitHub login." >&2
    detail=$(echo "$auth_json" | jq -r '.errors[0].detail // empty' 2>/dev/null || true)
    [[ -n "$detail" ]] && echo "       server said: ${detail}" >&2
    exit 1
    ;;
  429)
    echo "error: rate limited (HTTP 429). The API throttles token requests;" >&2
    echo "       wait a minute and try again." >&2
    exit 1
    ;;
  *)
    echo "error: unexpected response from ${API}/tokens (HTTP ${auth_code})" >&2
    echo "$auth_json" | head -c 400 >&2; echo >&2
    exit 1
    ;;
esac

token=$(echo "$auth_json" | jq -r '.data.attributes.access // empty' 2>/dev/null || true)
if [[ -z "$token" ]]; then
  echo "error: authenticated but no access token in the response." >&2
  echo "$auth_json" | head -c 400 >&2; echo >&2
  exit 1
fi

# YAML -> JSON, so the file stays comment-friendly for humans (the reasoning
# for each muted check lives in comments and in Description) while the API
# receives the JSON:API document it expects.
#
# PyYAML is not in macOS's system python, so fall back to the API container's
# virtualenv, which has it. The stack has to be running for the API call below
# anyway, so this costs nothing.
CONV='import json,sys,yaml; print(json.dumps(yaml.safe_load(sys.stdin)))'

to_json() {
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c "$CONV" < "$FILE"
  elif docker compose exec -T api /home/prowler/.venv/bin/python -c 'import yaml' 2>/dev/null; then
    docker compose exec -T api /home/prowler/.venv/bin/python -c "$CONV" < "$FILE"
  else
    return 1
  fi
}

if ! config=$(to_json 2>/dev/null); then
  echo "error: cannot parse ${FILE} — no python with PyYAML available." >&2
  echo "       Install it on the host (pip install pyyaml), or start the" >&2
  echo "       stack (make up) so the API container can do the conversion." >&2
  exit 1
fi

echo "$config" | jq -e '.Mutelist.Accounts' >/dev/null \
  || { echo "error: $FILE has no Mutelist.Accounts key" >&2; exit 1; }

muted=$(echo "$config" | jq -r '[.Mutelist.Accounts[].Checks | keys[]] | unique | join(", ")')
echo "    checks to mute: ${muted}"

# Same pattern as the auth call: capture body + status, report failures in words.
api_call() {
  local method=$1 url=$2 data=${3:-}
  local out
  if [[ -n "$data" ]]; then
    out=$(curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/vnd.api+json" \
      -H "Accept: application/vnd.api+json" \
      -w '\n%{http_code}' --data-binary "$data" 2>/dev/null) || return 1
  else
    out=$(curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.api+json" \
      -w '\n%{http_code}' 2>/dev/null) || return 1
  fi
  API_CODE=${out##*$'\n'}
  API_BODY=${out%$'\n'*}
}

fail_api() {
  echo "error: $1 (HTTP ${API_CODE})" >&2
  echo "$API_BODY" | jq -r '.errors[]? | "       " + (.detail // .title // "")' 2>/dev/null \
    || echo "$API_BODY" | head -c 400 >&2
  exit 1
}

echo "==> Looking for an existing mutelist processor"
api_call GET "${API}/processors?filter[processor_type]=mutelist" \
  || { echo "error: could not reach ${API}/processors" >&2; exit 1; }
[[ "$API_CODE" == 200 ]] || fail_api "could not list processors"

existing=$(echo "$API_BODY" | jq -r '.data[0].id // empty' 2>/dev/null || true)

if [[ -n "$existing" ]]; then
  echo "    updating processor ${existing}"
  body=$(jq -n --arg id "$existing" --argjson cfg "$config" '{
    data: { type: "processors", id: $id, attributes: { configuration: $cfg } }
  }')
  api_call PATCH "${API}/processors/${existing}" "$body" \
    || { echo "error: PATCH request failed" >&2; exit 1; }
  [[ "$API_CODE" == 200 ]] || fail_api "could not update the mutelist"
  echo "    updated: $(echo "$API_BODY" | jq -r '.data.id')"
else
  echo "    creating a new mutelist processor"
  body=$(jq -n --argjson cfg "$config" '{
    data: { type: "processors", attributes: { processor_type: "mutelist", configuration: $cfg } }
  }')
  api_call POST "${API}/processors" "$body" \
    || { echo "error: POST request failed" >&2; exit 1; }
  [[ "$API_CODE" =~ ^20[01]$ ]] || fail_api "could not create the mutelist"
  echo "    created: $(echo "$API_BODY" | jq -r '.data.id')"
fi

echo
echo "Done. Mutelists apply to findings as they are produced, so run a new scan"
echo "to see the effect — existing findings keep their current status."
