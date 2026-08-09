# Troubleshooting

Start with `make preflight` — it catches most setup problems before they become container failures.

## A port is already in use

The stack publishes six host ports: 3000 (UI), 8000 (MCP), 5432 (postgres), 6379 (valkey), 7687 (neo4j), 8080 (API).

Find the offender:

```bash
lsof -nP -iTCP:5432 -sTCP:LISTEN
```

A local postgres or redis is the usual culprit. Either stop it, or remap Prowler's port in `.env`:

```env
POSTGRES_PORT=5433
VALKEY_PORT=6380
UI_PORT=3001
```

`UI_PORT` also needs `AUTH_URL` updated to match, or sign-in redirects break:

```env
UI_PORT=3001
AUTH_URL=http://localhost:3001
```

`DJANGO_PORT` is riskier to change — it appears in `API_BASE_URL`, `UI_API_DOCS_URL` and the API healthcheck. Change all of them together or leave 8080 alone.

The MCP server's port 8000 is hardcoded in `docker-compose.yml`, not driven by `.env`. Edit the compose file if you must move it.

## The UI never starts

`ui` has `depends_on: mcp-server: service_healthy`, so it will not start at all while the MCP server is unhealthy. Check that one first:

```bash
docker compose ps
make logs S=mcp-server
```

## A container keeps restarting

```bash
make logs S=api
make logs S=worker
```

Common causes:

- **`api` exits during migrations** — postgres wasn't ready or credentials in `.env` don't match what postgres was *first initialized* with. Postgres only reads `POSTGRES_USER`/`POSTGRES_PASSWORD` when it creates the data directory; changing them later in `.env` has no effect on an existing `_data/postgres`. Fix by matching `.env` to the original values, or `make purge` and start clean.
- **`neo4j` unhealthy or OOM-killed** — it's configured for 1 GB heap + 1 GB page cache. Raise Docker Desktop's memory limit, or lower `NEO4J_SERVER_MEMORY_HEAP_MAX__SIZE` and `NEO4J_SERVER_MEMORY_PAGECACHE_SIZE` in `.env`.
- **Permission errors on `_data/`** — the `api-init` service chowns `_data/api` to uid 1000 on every start. If it failed, `docker compose up api-init` and read its output.

## "Check connection" fails when adding AWS

In order of likelihood:

1. The access key or secret was truncated on copy — re-paste both.
2. The account ID doesn't match the account the IAM user belongs to. Verify with `aws sts get-caller-identity`.
3. Only one of `SecurityAudit` / `ViewOnlyAccess` is attached.
4. The key was created minutes ago and hasn't propagated — wait a minute and retry.
5. A session token was pasted for a permanent key. Leave that field empty unless the credentials are temporary (`ASIA...` keys).

## A scan starts but never finishes

A full account scan legitimately takes 10–30 minutes, longer in accounts with many resources across many regions.

If it's genuinely stuck:

```bash
make logs S=worker
```

- **Throttling** (`Rate exceeded`) — Prowler backs off and retries; slow is normal, not stuck.
- **`AccessDenied` on specific checks** — expected for checks needing the optional additions policy. Those report as errors; the rest of the scan continues.
- **Worker not consuming at all** — check `valkey` is healthy and that `VALKEY_HOST=valkey` in `.env` (`localhost` only applies when running the API outside Docker).

## Everything is broken, start over

```bash
make purge      # deletes all local data, prompts for confirmation
make setup      # re-fetch compose + .env for the pinned version
make secrets
make up
```

## Upgrading Prowler

```bash
make upgrade    # pins the latest release, backs up .env to .env.bak
```

Then diff `.env.bak` against the new `.env` and re-apply anything you'd customized — including your rotated `AUTH_SECRET` and `DJANGO_SECRETS_ENCRYPTION_KEY`. Carrying over the encryption key matters: without it, the AWS credentials already in postgres can't be decrypted.

```bash
diff .env.bak .env
```
