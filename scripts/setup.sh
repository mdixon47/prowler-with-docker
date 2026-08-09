#!/usr/bin/env bash
# Download the Prowler docker-compose.yml and .env for a pinned release.
#
#   ./scripts/setup.sh              # use the version in .prowler-version
#   ./scripts/setup.sh latest       # resolve + pin the latest GitHub release
#   ./scripts/setup.sh v5.38.0      # pin a specific tag
#
# Existing files are backed up to *.bak before being overwritten.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="prowler-cloud/prowler"
RAW="https://raw.githubusercontent.com/${REPO}/refs/tags"

resolve_latest() {
  local tag
  tag=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | jq -r .tag_name)
  [[ -n "$tag" && "$tag" != "null" ]] || { echo "error: could not resolve latest release" >&2; exit 1; }
  echo "$tag"
}

arg="${1:-}"
case "$arg" in
  ""|pinned)
    [[ -f .prowler-version ]] || { echo "error: no .prowler-version — run: $0 latest" >&2; exit 1; }
    VERSION=$(tr -d '[:space:]' < .prowler-version)
    ;;
  latest) VERSION=$(resolve_latest) ;;
  *)      VERSION="$arg" ;;
esac

echo "==> Prowler ${VERSION}"

# The upstream .env carries secret keys that encrypt stored cloud credentials.
# Overwriting it after a scan orphans those secrets, so warn before clobbering.
if [[ -f .env ]]; then
  echo "    .env exists — backing up to .env.bak (rotate-secrets.sh values will be lost)"
  cp .env .env.bak
fi
[[ -f docker-compose.yml ]] && cp docker-compose.yml docker-compose.yml.bak

for f in docker-compose.yml .env; do
  echo "    fetching ${f}"
  curl -fsSL -o "$f" "${RAW}/${VERSION}/${f}" \
    || { echo "error: ${f} not found for tag ${VERSION}" >&2; exit 1; }
done

echo "$VERSION" > .prowler-version

echo
echo "Done. Next:"
echo "  ./scripts/rotate-secrets.sh   # replace the shipped default secret keys"
echo "  ./scripts/preflight.sh        # check ports, RAM, docker"
echo "  make up                       # start the stack"
