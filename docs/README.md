# Prowler Local Server with Docker Compose

Run [Prowler](https://prowler.com) — an open source cloud security platform — on your own machine, connect it to an AWS account with read-only credentials, and scan the account from a web UI.

Prowler runs 500+ checks against AWS (IAM, S3, EC2, RDS, CloudTrail, and more) and maps the results to CIS, NIST, PCI-DSS, HIPAA and SOC 2.

**Level:** beginner · **Time:** 45–60 min · **Cost:** free (scans are read-only AWS API calls)

---

## What you get

| Command | What it does |
| --- | --- |
| `make setup` | Download the `docker-compose.yml` + `.env` for the pinned release |
| `make secrets` | Replace the secret keys that ship as public defaults |
| `make preflight` | Check docker, ports, RAM and secrets before starting |
| `make up` | Start the stack |
| `make status` | Check whether the UI and API are answering |
| `make logs S=api` | Tail one service |
| `make down` | Stop, keeping all scan data |
| `make purge` | Stop and delete every trace of local data |
| `make upgrade` | Pin and fetch the newest Prowler release |
| `make tf-apply` | Create the AWS-side IAM identity with Terraform ([terraform.md](terraform.md)) |
| `make tf-destroy` | Delete it again — the cleanup step people forget |
| `make ci` | Run every check CI runs that works offline ([ci.md](ci.md)) |

Pinned release: see [.prowler-version](../.prowler-version) (currently **5.38.0**).

> All project documentation lives in this `docs/` folder — [learn.md](learn.md) for the concepts behind the tool, [terraform.md](terraform.md) for the AWS-side provisioning, [ci.md](ci.md) for the GitHub Actions workflows, [issue.md](issue.md) for the known-issues log, [code_review.md](code_review.md) for a review of the tooling here. Only `Claude.md` stays at the repo root — a rule CI enforces.

## Prerequisites

- **Docker Desktop** with Compose v2 — `docker compose version`
- **A personal AWS account you own or are authorized to scan.** Never scan an account you don't have permission to assess.
- AWS console access with permission to create an IAM user and access keys
- **~6 GB of RAM available to Docker.** The stack is eight long-running services, and neo4j alone is configured for 1 GB heap + 1 GB page cache. 4 GB works but is tight — raise the limit in Docker Desktop → Settings → Resources.
- **Six free host ports:** 3000, 8000, 5432, 6379, 7687, 8080. `make preflight` checks all of them.
- ~10 GB free disk for images and scan data

> The published walkthrough for older releases mentions only ports 3000/8080 and ~4 GB of RAM. That was accurate when the stack was six services; v5.38 adds neo4j (attack-path graph) and an MCP server, which is why the numbers here are higher.

## Quick start

```bash
make setup        # only needed if docker-compose.yml / .env are missing
make secrets      # rotate the default encryption keys — do this BEFORE adding AWS
make up
make status       # repeat until both report up; first start takes a few minutes
```

Then open <http://localhost:3000>.

---

## Step 1 — Start the stack

`make up` runs preflight and then `docker compose up -d`. The first launch pulls several GB of images and runs database migrations, so expect a few minutes before anything answers.

Services you should see in `make ps`:

| Service | Role | Host port |
| --- | --- | --- |
| `ui` | Next.js web UI | 3000 |
| `api` | Django REST API | 8080 |
| `worker` | Celery worker that executes scans | — |
| `worker-beat` | Scheduler for the 24 h re-scan | — |
| `postgres` | Findings, users, providers | 5432 |
| `valkey` | Task queue | 6379 |
| `neo4j` | Attack-path graph | 7687 |
| `mcp-server` | MCP endpoint the UI depends on | 8000 |

If `ui` never comes up, check `mcp-server` first — the UI declares a hard `depends_on: service_healthy` against it, so an unhealthy MCP server keeps the UI from starting at all.

## Step 2 — Create your local account

At <http://localhost:3000>, click **Sign up** and create an account with an email and password. This account lives only in your local postgres — it is not connected to Prowler Cloud or to AWS.

You'll land on an empty **Overview**. That's expected until a scan has run.

The API's generated docs are at <http://localhost:8080/api/v1/docs>.

## Step 3 — Create read-only AWS credentials

Full instructions, including the exact policies and the key-deletion cleanup: **[aws-iam-setup.md](aws-iam-setup.md)**.

Short version: create an IAM user `prowler-scan` with no console access, attach the AWS-managed `SecurityAudit` and `ViewOnlyAccess` policies, and create an access key.

Or provision it with Terraform — `make tf-apply`, then `make tf-creds`. See **[terraform.md](terraform.md)**, including the warning about the secret landing in Terraform state.

> These keys grant read access to your entire account. Don't commit them, don't share them, and delete them when you're done.

## Step 4 — Connect AWS in the UI

1. **Settings → Providers → Add Provider** (called **Configuration → Providers** in some versions)
2. Choose **Amazon Web Services**
3. Enter your 12-digit **AWS Account ID** and an optional alias
4. Authentication method: **Credentials** (static access keys), not Assumed Role
5. Paste the access key ID and secret. Leave session token blank — that's only for temporary credentials.
6. **Check connection**

If the check fails: confirm the key was copied in full, that the account ID belongs to the same account the IAM user lives in, and that both managed policies are attached.

## Step 5 — Run a scan

Save the provider and click **Launch Scan**, then watch **Scans**. A full scan covers every enabled check across all regions — roughly 10–30 minutes depending on how much is deployed in the account.

No check selection or region tuning needed; the default whole-account scan is exactly the right first baseline.

While the stack is running, `worker-beat` re-scans connected providers every 24 hours, so this doubles as a lightweight continuous-assessment setup.

## Step 6 — Read the results

Three views, three different questions:

- **Overview** — posture at a glance: total findings, pass/fail, severity breakdown.
- **Compliance** — the same results mapped onto CIS AWS Foundations Benchmark, NIST, PCI-DSS and others, each with a completion percentage and a downloadable CSV.
- **Findings** — every check result. Filter by severity (start Critical/High), status (FAIL) and service. Each finding names the specific resource and what's wrong with it.

**Scans** also offers a ZIP of the complete results as CSV, JSON-OCSF and HTML.

A large findings count is normal for any real account and most of it will be low severity. Triage rule of thumb: anything Critical or High involving public exposure or IAM first.

## Step 7 — Clean up

**Delete the AWS credentials** even if you keep Prowler running — see [aws-iam-setup.md#cleanup](aws-iam-setup.md#cleanup).

**Stop Prowler, keeping data:**

```bash
make down
```

`make up` brings back your account, providers and scan history.

**Delete everything:**

```bash
make purge
```

> `docker compose down -v` is *not* enough on this stack. Postgres, valkey, neo4j and the API config are bind-mounted to `./_data/`, not stored in named volumes, so the data survives `-v`. `make purge` removes both.

---

## Security notes

- **Rotate the shipped secrets before connecting AWS.** The upstream `.env` publishes a default `DJANGO_SECRETS_ENCRYPTION_KEY`, and that key is what encrypts your stored AWS credentials in postgres. `make secrets` replaces it. Rotating *after* a provider is saved makes the stored secret undecryptable — you'd have to re-enter it.
- **`.env` is gitignored** because it holds those keys. `.prowler-version` is committed instead, so `make setup` can reproduce the pair.
- **Ports bind to all interfaces by default**, including postgres (5432) with the default password `postgres`. Fine on a laptop behind a firewall; do not run this as-is on a shared or internet-reachable host.
- **Static access keys are a learning shortcut.** For anything ongoing, switch the provider to IAM role assumption.

## Troubleshooting

See **[troubleshooting.md](troubleshooting.md)** for port conflicts, unhealthy containers, failed connection checks and stalled scans. Anything known-and-still-open is tracked in [issue.md](issue.md).

## Where to go next

- Triage one Critical finding end to end and remediate it
- Switch from access keys to **IAM role assumption**
- Add other providers — Azure, GCP, Kubernetes, GitHub ([docs](https://docs.prowler.com))
