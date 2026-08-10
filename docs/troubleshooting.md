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

A full account scan legitimately takes 10–30 minutes, longer in accounts with many resources across many regions. Genuinely stuck is different, and has a specific signature.

### First: is it stalled, or just slow?

```bash
docker compose exec -T postgres psql -U prowler_admin -d prowler_db -c \
  "select state, progress, (now()-started_at)::interval(0) as running_for,
          (now()-updated_at)::interval(0) as since_last_update
     from scans where state='executing';"
```

If `since_last_update` is more than a few minutes, it is stalled, not slow.

### The most likely cause: the worker was OOM-killed

Confirmed on this setup — a scan died at 95% with 630 findings already written:

```bash
docker inspect prowler-with-docker-worker-1 --format 'OOMKilled={{.State.OOMKilled}}'
docker compose logs worker | grep -E "SIGKILL|exited with"
```

```
OOMKilled=true
ERROR/MainProcess] Process 'ForkPoolWorker-129' pid:2162 exited with 'signal 9 (SIGKILL)'
```

Two things conspire here:

1. **Celery defaults its pool size to the CPU count.** On a 12-core machine that is 12 forked children, each loading the full Django app, before a single scan starts. The scanning child then grows into whatever is left.
2. **Orphan task recovery is disabled** in this build — the worker logs `Orphan task recovery disabled by feature flag` every two minutes. So when the task dies, the scan row stays `executing` forever, and because Prowler runs one scan per provider at a time, **every later scan queues behind a scan that is already dead**.

The symptom people notice is the queue, not the crash.

### Fix

**1. Cap the Celery pool.** [`docker-compose.override.yml`](../docker-compose.override.yml) sets `DJANGO_CELERY_WORKER_CONCURRENCY: "4"`. That exact variable is read by Prowler's `config/settings/celery.py`; verify it applied with:

```bash
docker compose logs worker | grep concurrency     # => concurrency: 4 (prefork)
```

**2. Trim neo4j** in `.env` — attack-path graphs are unused on a small account, and the JVM reserves heap and page cache up front. `.env` is gitignored, so these values are recorded here rather than in the repo:

```env
NEO4J_SERVER_MEMORY_PAGECACHE_SIZE=512m
NEO4J_SERVER_MEMORY_HEAP_INITIAL__SIZE=512m
NEO4J_SERVER_MEMORY_HEAP_MAX__SIZE=512m
```

Together these took idle usage from **5.4 GiB to ~3.9 GiB**.

**3. Raise Docker Desktop's memory** — Settings → Resources → Memory. This is the actual fix; the rest is headroom. 12–16 GiB is sensible on a 32 GB machine.

> Do **not** add a `mem_limit` to the `worker` service to "contain" it. Capping the container makes the OOM arrive sooner — the scanning child needs room to finish.

### Clearing a stuck scan and the scans queued behind it

Nothing will clear these on its own while orphan recovery is disabled. Back up first:

```bash
docker compose exec -T postgres psql -U prowler_admin -d prowler_db -c \
  "\copy (select * from scans) to stdout with csv header" > scans-backup.csv
```

Then mark the dead scan failed and cancel the phantom queue:

```sql
BEGIN;
UPDATE scans SET state='failed', completed_at=updated_at,
       duration=GREATEST(0, EXTRACT(EPOCH FROM (updated_at - started_at))::int)
 WHERE state='executing';
UPDATE scans SET state='cancelled', completed_at=now()
 WHERE state='available';
COMMIT;
```

Cancel rather than delete — findings already written stay browsable, and the history shows what happened. Check the queues really are empty first, so nothing resurrects:

```bash
docker compose exec -T valkey valkey-cli llen scans     # expect 0
```

### Other causes

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
