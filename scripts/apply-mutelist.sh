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

email="${PROWLER_EMAIL:-}"
if [[ -z "$email" ]]; then
  read -r -p "Prowler email: " email
fi
# -s: no echo. The password never reaches the process list or the shell history.
read -r -s -p "Prowler password: " password
echo

echo "==> Authenticating"
token=$(jq -n --arg e "$email" --arg p "$password" '{
  data: { type: "tokens", attributes: { email: $e, password: $p } }
}' | curl -sfL -X POST "${API}/tokens" \
      -H "Content-Type: application/vnd.api+json" \
      -H "Accept: application/vnd.api+json" \
      --data-binary @- | jq -r '.data.attributes.access // empty')

unset password
[[ -n "$token" ]] || { echo "error: authentication failed — check the email and password" >&2; exit 1; }

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

echo "==> Looking for an existing mutelist processor"
existing=$(curl -sfL "${API}/processors?filter[processor_type]=mutelist" \
  -H "Authorization: Bearer ${token}" \
  -H "Accept: application/vnd.api+json" | jq -r '.data[0].id // empty')

if [[ -n "$existing" ]]; then
  echo "    updating processor ${existing}"
  body=$(jq -n --arg id "$existing" --argjson cfg "$config" '{
    data: { type: "processors", id: $id, attributes: { configuration: $cfg } }
  }')
  curl -sfL -X PATCH "${API}/processors/${existing}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/vnd.api+json" \
    -H "Accept: application/vnd.api+json" \
    --data-binary "$body" | jq -r '"    updated: " + .data.id'
else
  echo "    creating a new mutelist processor"
  body=$(jq -n --argjson cfg "$config" '{
    data: { type: "processors", attributes: { processor_type: "mutelist", configuration: $cfg } }
  }')
  curl -sfL -X POST "${API}/processors" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/vnd.api+json" \
    -H "Accept: application/vnd.api+json" \
    --data-binary "$body" | jq -r '"    created: " + .data.id'
fi

echo
echo "Done. Mutelists apply to findings as they are produced, so run a new scan"
echo "to see the effect — existing findings keep their current status."
