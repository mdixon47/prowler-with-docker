#!/usr/bin/env bash
# Stop the stack, and optionally destroy stored data.
#
#   ./scripts/teardown.sh          # stop containers, keep all data
#   ./scripts/teardown.sh --purge  # stop and delete _data/ + volumes (irreversible)
#
# Note: `docker compose down -v` alone does NOT wipe your data on this stack.
# Postgres, valkey, neo4j and the API config are bind-mounted to ./_data/, so a
# full teardown has to remove that directory too.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--purge" ]]; then
  echo "This deletes ALL local Prowler data: scan history, findings, users, and"
  echo "the stored AWS provider credentials in ./_data/."
  read -r -p "Type 'purge' to confirm: " reply
  [[ "$reply" == "purge" ]] || { echo "Aborted."; exit 1; }

  docker compose down -v --remove-orphans
  # _data is created by containers running as uid 1000/postgres, so some paths
  # may not be writable by the current user.
  if ! rm -rf _data 2>/dev/null; then
    echo "    some files need root to remove; retrying via a container"
    docker run --rm -v "$PWD:/work" -w /work busybox:1.37.0 rm -rf _data
  fi
  echo 'Purged. `make up` will start from a clean database.'
else
  docker compose down --remove-orphans
  echo 'Stopped. Data kept in ./_data/ — `make up` restores everything.'
fi

echo
echo "Reminder: also delete the prowler-scan IAM access key in the AWS console."
echo "See docs/aws-iam-setup.md#cleanup"
