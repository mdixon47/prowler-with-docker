#!/usr/bin/env bash
# Check the host can actually run the stack before `make up`.
# Exits non-zero if anything hard-blocking is wrong.
# No -e: this script collects every problem before exiting, rather than
# stopping at the first one. That makes the cd guard below load-bearing.
set -uo pipefail

cd "$(dirname "$0")/.." || { echo "error: cannot enter project root" >&2; exit 1; }
fail=0
warn=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
note() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; warn=1; }

echo "==> Tooling"
if docker compose version >/dev/null 2>&1; then
  ok "docker compose $(docker compose version --short 2>/dev/null)"
else
  bad "docker compose not available (install Docker Desktop / compose v2)"
fi
docker info >/dev/null 2>&1 && ok "docker daemon running" || bad "docker daemon not running"

echo "==> Files"
for f in docker-compose.yml .env; do
  [[ -f $f ]] && ok "$f present" || bad "$f missing — run ./scripts/setup.sh latest"
done

echo "==> Secrets"
if [[ -f .env ]]; then
  # These two ship with public defaults upstream. DJANGO_SECRETS_ENCRYPTION_KEY
  # encrypts the AWS keys Prowler stores in postgres.
  grep -q 'AUTH_SECRET="N/c6mnaS5+SWq81+819OrzQZlmx1Vxtp/orjttJSmw8="' .env \
    && note "AUTH_SECRET is the upstream default — run ./scripts/rotate-secrets.sh" \
    || ok "AUTH_SECRET changed from default"
  grep -q 'DJANGO_SECRETS_ENCRYPTION_KEY="oE/ltOhp/n1TdbHjVmzcjDPLcLA41CVI/4Rk+UB5ESc="' .env \
    && note "DJANGO_SECRETS_ENCRYPTION_KEY is the upstream default — run ./scripts/rotate-secrets.sh" \
    || ok "DJANGO_SECRETS_ENCRYPTION_KEY changed from default"
fi

echo "==> Ports"
# The 5.38 stack publishes more than the UI and API: postgres, valkey, neo4j
# and the MCP server all bind host ports too.
check_port() {
  local port=$1 what=$2
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    bad "$port ($what) already in use — $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fc 2>/dev/null | grep '^c' | head -1 | cut -c2-)"
  else
    ok "$port ($what) free"
  fi
}
check_port 3000 "UI"
check_port 8080 "API"
check_port 8000 "MCP server"
check_port 5432 "postgres"
check_port 6379 "valkey"
check_port 7687 "neo4j"

echo "==> Resources"
mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
if [[ "$mem_bytes" =~ ^[0-9]+$ ]] && (( mem_bytes > 0 )); then
  mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
  # neo4j alone is configured for 1G heap + 1G pagecache; the full stack is
  # eight long-running services. 4 GB is tight, 6 GB is comfortable.
  if   (( mem_gb >= 6 )); then ok "docker has ${mem_gb} GB RAM"
  elif (( mem_gb >= 4 )); then note "docker has ${mem_gb} GB RAM — workable but tight; 6 GB+ recommended"
  else bad "docker has only ${mem_gb} GB RAM — raise Docker Desktop's memory limit to at least 4 GB"
  fi
else
  note "could not read docker's memory limit (daemon down?) — the stack wants 6 GB"
fi
avail_gb=$(df -g . 2>/dev/null | awk 'NR==2 {print $4}')
[[ -n "${avail_gb:-}" ]] && { (( avail_gb >= 10 )) && ok "${avail_gb} GB disk free" || note "${avail_gb} GB disk free — images + scan data want ~10 GB"; }

echo
if (( fail )); then
  echo "Preflight FAILED — fix the items above before starting."
  exit 1
fi
(( warn )) && echo "Preflight passed with warnings." || echo "Preflight passed."
