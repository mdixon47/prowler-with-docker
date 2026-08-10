# Deploy Prowler with Docker Compose and scan your AWS account

A practical, approachable introduction to cloud security assessment. You'll go from an empty Docker host to a scanned AWS account, a compliance report, and a concrete list of misconfigurations to fix.

Run [Prowler](https://prowler.com) — an open source cloud security platform — on your own machine, connect it to an AWS account with read-only credentials, and scan that account from a web UI.

Prowler runs 500+ checks against AWS (IAM, S3, EC2, RDS, CloudTrail and more) and maps the results to CIS, NIST, PCI-DSS, HIPAA and SOC 2.

**Level:** beginner · **Time:** 45–60 min · **Cost:** free (scans are read-only AWS API calls)

Pinned release: [.prowler-version](.prowler-version) — currently **5.38.0**.

---

## Contents

**Getting started**
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Repository layout](#repository-layout)

**Walkthrough**
- [Step 1 — Start the stack](#step-1--start-the-stack)
- [Step 2 — Create your local account](#step-2--create-your-local-account)
- [Step 3 — Create read-only AWS credentials](#step-3--create-read-only-aws-credentials)
- [Step 4 — Apply the mutelist](#step-4--apply-the-mutelist)
- [Step 5 — Connect AWS in the UI](#step-5--connect-aws-in-the-ui)
- [Step 6 — Run a scan](#step-6--run-a-scan)
- [Step 7 — Read the results](#step-7--read-the-results)
- [Step 8 — Clean up](#step-8--clean-up)

**Reference**
- [Command reference](#command-reference)
- [Resource tuning](#resource-tuning)
- [Security notes](#security-notes)
- [Documentation map](#documentation-map)
- [Troubleshooting](#troubleshooting)
- [Where to go next](#where-to-go-next)

---

## Prerequisites

- **Docker Desktop** with Compose v2 — check with `docker compose version`
- **A personal AWS account you own or are authorized to scan.** Never scan an account you don't have permission to assess.
- AWS credentials with permission to create an IAM user, role and policies
- **8 GB of RAM allocated to Docker, 12 GB preferred.** See [Resource tuning](#resource-tuning) — this is the single most common cause of failure.
- **Six free host ports:** 3000, 8000, 5432, 6379, 7687, 8080. `make preflight` checks all of them.
- ~10 GB free disk for images and scan data
- Optional: [Terraform](https://terraform.io) ≥ 1.5 to provision the AWS side; `jq`; `shellcheck` and `checkov` for the local checks

> The published walkthrough for older Prowler releases mentions only ports 3000/8080 and ~4 GB of RAM. That was accurate when the stack was six services. 5.38 adds neo4j (attack-path graph) and an MCP server, which is why the numbers here are higher.

## Quick start

```bash
make setup        # fetch docker-compose.yml + .env for the pinned release
make secrets      # rotate the published default keys — BEFORE connecting AWS
make up           # start the stack (runs preflight first)
make status       # repeat until UI and API answer; first start takes minutes
```

Then open <http://localhost:3000>.

To provision the AWS side too:

```bash
make tf-init && make tf-plan && make tf-apply
make tf-creds     # account ID + access key ID
make -s tf-secret # the secret, on its own
```

## Repository layout

```
README.md                    this file — the walkthrough
Claude.md                    the original walkthrough
Makefile                     every command below
docker-compose.yml           fetched from upstream, gitignored
docker-compose.override.yml  local tuning that survives upgrades
.env                         fetched from upstream, gitignored — holds secrets
.prowler-version             the pinned release, committed
config/mutelist.yaml         deliberately accepted findings
scripts/                     setup, preflight, secret rotation, teardown, mutelist, docs check
terraform/                   the read-only IAM identity Prowler scans with
docs/                        all documentation
.github/                     CI, release watcher, Terraform plan, Dependabot
```

`docker-compose.yml` and `.env` are gitignored because they come from upstream and `.env` holds secrets. `.prowler-version` pins the release so `make setup` reproduces the exact pair.

---

## Step 1 — Start the stack

`make up` runs preflight and then `docker compose up -d`. The first launch pulls several GB of images and runs database migrations, so expect a few minutes before anything answers.

Eight long-running services, plus a one-shot `api-init` that fixes file ownership and exits:

| Service | Role | Host port |
| --- | --- | --- |
| `ui` | Next.js web UI | 3000 |
| `api` | Django REST API — the only service touching the database directly | 8080 |
| `worker` | Celery worker that executes scans | — |
| `worker-beat` | Scheduler for the 24 h re-scan | — |
| `postgres` | Findings, users, providers, encrypted credentials | 5432 |
| `valkey` | Task queue | 6379 |
| `neo4j` | Attack-path graph | 7687 |
| `mcp-server` | MCP endpoint the UI depends on | 8000 |

If `ui` never comes up, check `mcp-server` first — the UI declares a hard `depends_on: service_healthy` against it, so an unhealthy MCP server prevents the UI from starting at all, with nothing in the UI's own logs to explain it.

## Step 2 — Create your local account

At <http://localhost:3000>, click **Sign up** and create an account with an email and password.

This account lives only in your local postgres. It is not connected to Prowler Cloud, to AWS, or to anything else — but you will need it again for `make mutelist`.

You'll land on an empty **Overview**; that's expected until a scan has run. The API's generated docs are at <http://localhost:8080/api/v1/docs>.

## Step 3 — Create read-only AWS credentials

Two paths, both producing the same identity. Step-by-step for either is in [learn.md](docs/learn.md#creating-prowler-scan-step-by-step).

**Terraform (recommended)** — six resources, one command, and one command to remove them:

```bash
make tf-plan      # expect "6 to add, 0 to change, 0 to destroy"
make tf-apply
make tf-creds
```

**By hand** — create IAM user `prowler-scan` with no console access and attach `SecurityAudit` plus `ViewOnlyAccess`. Full detail in [aws-iam-setup.md](docs/aws-iam-setup.md).

> These credentials grant read access to your entire account. Don't commit them, don't share them, and delete them when you're done. With Terraform, the secret is also written to `terraform.tfstate` in plaintext — see [the state file warning](docs/terraform.md#the-state-file-holds-your-secret).

## Step 4 — Apply the mutelist

```bash
make mutelist
```

Optional, but **do it before the first scan**. Mutelists apply to findings as they are produced, so applying afterwards requires a second scan to take effect.

[`config/mutelist.yaml`](config/mutelist.yaml) records findings you have looked at and deliberately accepted, each with its reasoning and the condition that should make someone revisit it. See [mutelist.md](docs/mutelist.md).

## Step 5 — Connect AWS in the UI

1. **Settings → Providers → Add Provider** (called **Configuration → Providers** in some builds)
2. Choose **Amazon Web Services**
3. Enter your 12-digit **AWS Account ID** and an optional alias
4. Authentication method: **Credentials** — static access keys, not Assumed Role
5. Paste the access key ID and secret. **Leave the session token blank** — that field is only for temporary `ASIA…` credentials.
6. **Check connection**

If the check fails, the cause is almost always a truncated paste. Otherwise confirm the account ID matches the account the IAM user lives in, and that both managed policies are attached. Verify the key independently with:

```bash
AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… aws sts get-caller-identity
```

## Step 6 — Run a scan

> **Prowler starts a scan automatically the moment a provider is connected.** It appears with trigger `scheduled`, not `manual`, so it can look as though nothing happened. **Do not click Launch Scan repeatedly** — Prowler runs one scan per provider at a time, and the extra clicks simply queue behind the first.

Watch progress under **Scans**. A full scan covers every enabled check across all regions — roughly 10–30 minutes for a populated account, much less for a small one.

While the stack runs, `worker-beat` re-scans connected providers every 24 hours, so this doubles as lightweight continuous assessment.

If a scan stalls, read [Troubleshooting](#troubleshooting) before retrying — a stuck scan blocks every scan after it.

## Step 7 — Read the results

Three views answering three different questions:

- **Overview** — posture at a glance: total findings, pass/fail counts, severity breakdown.
- **Compliance** — the same findings mapped onto CIS AWS Foundations Benchmark, NIST, PCI-DSS and others, each with a completion percentage and a downloadable CSV. These are reinterpretations of one scan, not separate scans, which is why fixing one thing can move several frameworks.
- **Findings** — every check result. Filter by severity, status `FAIL`, and service. Each finding names the specific resource and what is wrong with it. This is the only view that produces a to-do list.

**Scans** also offers a ZIP of the complete results as CSV, JSON-OCSF and HTML.

A large findings count is normal. Triage order: Critical/High involving public exposure, then Critical/High involving IAM, then the rest in batches. Note that **severity describes the check, not your situation** — see [learn.md](docs/learn.md#reading-your-first-scan-without-panicking).

## Step 8 — Clean up

**Remove the AWS credentials** even if you keep Prowler running:

```bash
make tf-destroy      # or delete the key and user in the console
```

**Stop Prowler, keeping all data:**

```bash
make down
```

**Delete everything, including stored credentials and scan history:**

```bash
make purge
```

> `docker compose down -v` is **not** a full teardown here. Only one named volume exists (`output`); postgres, valkey, neo4j and the API config are bind-mounted to `./_data/` and survive `-v`. `make purge` removes both.

---

## Command reference

| Command | What it does |
| --- | --- |
| `make setup` | Download `docker-compose.yml` + `.env` for the pinned release |
| `make secrets` | Replace the secret keys that ship as public defaults |
| `make preflight` | Check docker, ports, RAM and secrets before starting |
| `make up` | Start the stack (runs preflight first) |
| `make status` | Check whether the UI and API answer (single check, not a wait) |
| `make ps` | Show container state |
| `make logs S=api` | Tail one service |
| `make down` | Stop, keeping all data |
| `make purge` | Stop and delete every trace of local data |
| `make upgrade` | Pin and fetch the newest Prowler release |
| `make mutelist` | Upload accepted findings ([mutelist.md](docs/mutelist.md)) |
| `make tf-init` / `tf-plan` / `tf-apply` | Provision the IAM identity ([terraform.md](docs/terraform.md)) |
| `make tf-creds` / `tf-secret` | Read the credentials back out |
| `make tf-destroy` | Delete the IAM identity — the cleanup step people forget |
| `make lint` / `docs-check` / `tf-check` | Individual checks |
| `make ci` | Everything CI runs that works offline ([ci.md](docs/ci.md)) |

## Resource tuning

The single most common failure is memory. Measured on this stack:

| | Idle usage |
| --- | --- |
| Upstream defaults | **5.4 GiB** |
| After the tuning below | **≈3.9 GiB** |

A scan grows well beyond idle. With only ~2 GiB of headroom, a scan was killed at 95% progress:

```
OOMKilled=true
Process 'ForkPoolWorker-129' exited with 'signal 9 (SIGKILL)'
```

Two tunings ship in [`docker-compose.override.yml`](docker-compose.override.yml) and `.env`:

**1. Cap the Celery pool.** Upstream starts the worker without `--concurrency`, so Celery defaults to the CPU count — 12 forked children on a 12-core machine, each loading the full Django app, before any scan begins. The override sets `DJANGO_CELERY_WORKER_CONCURRENCY: "4"`.

**2. Trim neo4j.** Attack-path graphs are unused on a small account, and the JVM reserves memory up front. In `.env` (gitignored, so recorded here):

```env
NEO4J_SERVER_MEMORY_PAGECACHE_SIZE=512m
NEO4J_SERVER_MEMORY_HEAP_INITIAL__SIZE=512m
NEO4J_SERVER_MEMORY_HEAP_MAX__SIZE=512m
```

**Neither replaces giving Docker more memory.** Raise it in Docker Desktop → Settings → Resources.

> Use `docker-compose.override.yml` for local changes, never `docker-compose.yml` — the latter is fetched from upstream and overwritten by `make setup` and `make upgrade`. Compose merges the override automatically.

## Security notes

- **Rotate the shipped secrets before connecting AWS.** The upstream `.env` publishes a default `DJANGO_SECRETS_ENCRYPTION_KEY`, and that key encrypts your stored AWS credentials in postgres. `make secrets` replaces it. Rotating *after* a provider is saved makes the stored secret undecryptable.
- **`.env` is gitignored** because it holds those keys. So are `*.tfstate*`, `terraform.tfvars`, `tfplan` and `_data/`.
- **Ports bind to all interfaces**, including postgres (5432, password `postgres`) and neo4j (7687). Fine on a laptop behind a firewall; do not run this as-is on a shared or internet-reachable host. Tracked as `ENV-3` in [issue.md](docs/issue.md).
- **Static access keys are a learning shortcut.** For anything ongoing, switch to IAM role assumption — `auth_method = "role"` in Terraform stores no long-lived secret at all.
- **Verify the scanner is read-only** after creating it: `aws iam create-user` with its credentials should return `AccessDenied`.

## Documentation map

All documentation lives in `docs/`. Only this README and `Claude.md` sit at the repo root — a rule CI enforces.

| Document | What it covers |
| --- | --- |
| [learn.md](docs/learn.md) | Concepts: what Prowler is, how the stack fits together, reading a first scan, and step-by-step credential creation |
| [aws-iam-setup.md](docs/aws-iam-setup.md) | Creating the IAM identity by hand, and deleting it |
| [terraform.md](docs/terraform.md) | Provisioning the IAM identity as code, both auth methods |
| [mutelist.md](docs/mutelist.md) | Recording deliberately accepted findings |
| [ci.md](docs/ci.md) | GitHub Actions workflows and the supply-chain approach |
| [troubleshooting.md](docs/troubleshooting.md) | Port conflicts, unhealthy containers, stalled scans |
| [issue.md](docs/issue.md) | Known issues and deviations, with status |
| [code_review.md](docs/code_review.md) | Review of the tooling in this repo |

## Troubleshooting

Start with [troubleshooting.md](docs/troubleshooting.md). The two failure modes worth knowing in advance:

**A scan stalls partway.** Almost always the worker being OOM-killed. Check with:

```bash
docker inspect prowler-with-docker-worker-1 --format 'OOMKilled={{.State.OOMKilled}}'
docker compose logs worker | grep SIGKILL
```

**Scans pile up in a queue.** Orphan task recovery is disabled in this build, so a scan whose worker died stays `executing` forever — and since Prowler runs one scan per provider at a time, everything after it queues behind a scan that is already dead. The queue is the symptom; the crash is the cause. Clearing SQL is in [troubleshooting.md](docs/troubleshooting.md#clearing-a-stuck-scan-and-the-scans-queued-behind-it).

Anything known and still open is tracked in [issue.md](docs/issue.md).

## Where to go next

- Triage one Critical finding end to end: read the resource, understand the exposure, remediate, re-scan, watch it turn green
- Switch from access keys to **IAM role assumption**
- Bind postgres and neo4j to `127.0.0.1` in the override file (`ENV-3`)
- Export OCSF JSON into something queryable — that format exists so results can leave the UI
- Add other providers — Azure, GCP, Kubernetes, GitHub ([docs](https://docs.prowler.com))
