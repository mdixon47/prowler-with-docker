#!/usr/bin/env bash
# Replace the secret keys that ship with the upstream .env.
#
# DJANGO_SECRETS_ENCRYPTION_KEY encrypts the cloud provider credentials Prowler
# stores in postgres. The published default is known to anyone who has read the
# repo, so change it BEFORE adding an AWS provider.
#
# Changing it afterwards makes already-stored credentials undecryptable — you
# would need to re-enter the provider secret in the UI.
set -euo pipefail

cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "error: .env missing — run ./scripts/setup.sh first" >&2; exit 1; }

if [[ -d _data/postgres && "${1:-}" != "--force" ]]; then
  echo "warn: _data/postgres exists, so credentials may already be stored." >&2
  echo "      Rotating now will make them undecryptable. Re-run with --force" >&2
  echo "      if you accept that, then re-enter the provider secret in the UI." >&2
  exit 1
fi

# Deliberately NOT .env.bak — setup.sh owns that name, and a later `make setup`
# would otherwise overwrite the only copy of the pre-rotation secrets.
cp .env .env.pre-rotate.bak
echo "    backed up .env -> .env.pre-rotate.bak"

set_var() {
  local key=$1 val=$2
  # macOS/BSD sed needs the empty -i argument. Escape backslash and & so base64
  # values land literally; / needs no escaping given the | delimiter.
  local esc=${val//\\/\\\\}; esc=${esc//&/\\&}
  sed -i '' -E "s|^${key}=.*|${key}=\"${esc}\"|" .env
}

AUTH_SECRET=$(openssl rand -base64 32)
ENC_KEY=$(openssl rand -base64 32)

set_var AUTH_SECRET "$AUTH_SECRET"
set_var DJANGO_SECRETS_ENCRYPTION_KEY "$ENC_KEY"

echo "    rotated AUTH_SECRET"
echo "    rotated DJANGO_SECRETS_ENCRYPTION_KEY"
echo
echo "Postgres/neo4j passwords are still the shipped defaults. That is fine for a"
echo "local-only setup; change POSTGRES_PASSWORD / NEO4J_PASSWORD before exposing"
echo "any of these ports beyond localhost."
