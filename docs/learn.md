# Learn: the concepts behind this project

[README.md](README.md) tells you which commands to run. This file explains what you're actually doing and why, so the scan results mean something when they arrive.

---

## Why cloud security assessments matter

Cloud accounts drift. A test bucket gets made public and nobody closes it. An IAM user keeps access keys that never rotate. Logging gets disabled in one region during a debugging session and stays off.

Most cloud breaches trace back to misconfigurations like these — not exotic exploits. Nothing was hacked; something was left open. Assessing an account on a schedule is how you find those before someone else does.

The uncomfortable property of drift is that it's invisible from inside your normal workflow. Nobody gets an alert when a bucket policy loosens. A scanner is how you make the current state legible.

## What Prowler is

Prowler is an open source cloud security platform. It authenticates to your cloud account with read-only credentials, calls the provider's own APIs to enumerate configuration, and evaluates each result against a library of checks.

For AWS that's 500+ checks across IAM, S3, EC2, RDS, CloudTrail and more. Each check is a small, named assertion — "S3 bucket has default encryption enabled", "root account has no active access keys" — that returns PASS, FAIL, or an error if it lacked permission to look.

It never writes. Nothing it does changes your account.

### The three flavors

| Flavor | What it is | Used here? |
| --- | --- | --- |
| **Prowler CLI** | A command-line scanner. Output to CSV/JSON/HTML. | No |
| **Prowler Local Server** (formerly "Prowler App") | Self-hosted web UI + API + workers. Stores history, schedules re-scans. | **Yes** |
| **Prowler Cloud** | The same thing, hosted as SaaS by Prowler. | No |

This project runs the Local Server. You get the UI's history and compliance mapping without sending account data anywhere — everything stays in containers on your machine.

## Three ways to use the results

The same scan answers three different questions depending on which view you open.

**1. Security review — "how bad is it?"**
The **Overview** page: total findings, pass/fail counts, severity breakdown. A point-in-time posture snapshot. Useful for tracking direction over weeks, not for deciding what to fix today.

**2. Compliance reporting — "do we meet the bar?"**
The **Compliance** page maps the same findings onto published frameworks — CIS AWS Foundations Benchmark, NIST, PCI-DSS, HIPAA, SOC 2 — each with a completion percentage and a downloadable CSV. This is the view that answers an auditor, or demonstrates due diligence without a manual evidence hunt.

Worth understanding: the frameworks are *reinterpretations of the same check results*, not separate scans. A single failing check can drag down several frameworks at once, which is why fixing one thing sometimes moves multiple percentages.

**3. Misconfiguration discovery — "what do I fix?"**
The **Findings** page. Every failed check names the specific resource and what's wrong with it. This is the only view that produces a to-do list. Filter to status FAIL, severity Critical/High, and work down.

## Reading your first scan without panicking

A large findings count is normal. A real account with real history will produce hundreds. That number is not a grade.

Useful triage order:

1. **Critical/High involving public exposure** — anything reachable from the internet that shouldn't be.
2. **Critical/High involving IAM** — over-broad permissions, unrotated keys, missing MFA on privileged identities.
3. **Everything else**, later, in batches by service.

Two categories to consciously set aside:

- **Errors, not failures.** Checks that couldn't run because your credentials lacked a permission. They're a coverage gap, not a security gap — see the optional additions policy in [aws-iam-setup.md](aws-iam-setup.md).
- **Accepted risk.** Some findings are deliberate for your account. A dev sandbox with a public static site bucket will fail a check forever, correctly.

Severity describes the check, not your situation. A HIGH on a resource holding nothing is less urgent than a MEDIUM on production data. The tool can't know which is which; you can.

## How the stack fits together

Eight long-running containers — plus a one-shot `api-init` that fixes file ownership on `_data/api` and exits. The division of labor explains most of the failure modes in [troubleshooting.md](troubleshooting.md).

```
                  browser :3000
                       |
                    [ ui ]  ──depends on──> [ mcp-server :8000 ]
                       |
                       v
                 [ api :8080 ]  ── Django REST API, the only thing that
                    /   |   \      talks to the database directly
                   /    |    \
        [ postgres ] [ valkey ] [ neo4j ]
          findings,   task       attack-path
          users,      queue      graph
          providers
                        ^
                        |
         [ worker ] ────┘   pulls scan jobs off the queue and runs the checks
         [ worker-beat ]    puts a job on the queue every 24h
```

- **The UI never scans.** It's a thin client over the API. A scan you launch in the browser becomes a queued job.
- **`worker` does the actual work** — it holds your AWS credentials in memory, makes the API calls, and writes findings. Long scans mean a busy worker; that's where scan logs live.
- **`worker-beat`** is the scheduler and the reason a running stack re-scans every 24 hours on its own. It's what makes this lightweight continuous assessment rather than a one-shot tool.
- **`postgres` holds everything you care about**, including your AWS credentials, encrypted with `DJANGO_SECRETS_ENCRYPTION_KEY` from `.env`. That's the whole reason `make secrets` exists and why it must run *before* you add a provider.
- **`neo4j` and `mcp-server` are newer additions** (attack-path graphs and an MCP endpoint). You don't interact with them directly, but the UI hard-depends on the MCP server's health, so a broken one looks like "the UI won't start."

## Credentials: why read-only, and why temporary

Prowler needs to *describe* and *list*, never to create or modify. The two AWS-managed policies it asks for — `SecurityAudit` and `ViewOnlyAccess` — grant exactly that shape of access, account-wide.

That's still a lot. A read of your whole account reveals resource names, network layout, IAM structure, which services you run and where. Treat a leaked scanning key as reconnaissance handed to an attacker, even though it can't change anything.

Two mitigations, in increasing order of maturity:

- **Static access keys** (what this walkthrough uses) — simplest to learn, but a long-lived secret that sits in Prowler's database. Delete the key when you're done.
- **IAM role assumption** (recommended for anything ongoing) — Prowler assumes a role and receives short-lived credentials. Nothing long-lived is stored at all.

Starting with keys is a reasonable learning shortcut precisely because the cleanup is easy and complete: delete the key, and the access is gone regardless of what leaked.

## Creating `prowler-scan`, step by step

Two ways to create the identity. Both produce the same thing; pick one.

> Throughout, `<ACCOUNT_ID>` means your own 12-digit AWS account ID. Get it with
> `aws sts get-caller-identity --query Account --output text`. Don't paste it into
> anything you publish — it isn't a secret, but it's useful to someone enumerating
> your account, so this repo keeps it out of tracked files.

### Before you start: confirm you can create IAM identities

```bash
aws sts get-caller-identity
```

The `Arn` should be an identity you recognize as having admin or IAM-write rights. Confirm nothing blocks the specific calls:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "$(aws sts get-caller-identity --query Arn --output text)" \
  --action-names iam:CreateUser iam:CreateAccessKey iam:CreatePolicy \
                 iam:AttachUserPolicy iam:CreateRole iam:DeleteUser \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
```

Every row should say `allowed`. This catches a Service Control Policy or permissions boundary that `AdministratorAccess` alone doesn't reveal — the kind of thing that otherwise surfaces halfway through an apply.

Then check the names are free, so you don't collide with an earlier attempt:

```bash
aws iam get-user --user-name prowler-scan          # expect NoSuchEntity
```

---

### Path A — Terraform (recommended)

Six resources, one command, and a single command to remove them again. Full detail in [terraform.md](terraform.md).

**1. Configure it.**

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

The defaults create an IAM user with an access key, which matches the walkthrough. Leave them alone for a first run.

**2. Read the plan before it touches anything.**

```bash
make tf-plan
```

Expect `Plan: 6 to add, 0 to change, 0 to destroy`:

| Resource | What it is |
| --- | --- |
| `aws_iam_user.prowler` | `prowler-scan`, path `/security/`, no console access |
| `aws_iam_access_key.prowler` | The key pair you paste into Prowler |
| `aws_iam_policy.additions` | `prowler-scan-additions` |
| `aws_iam_user_policy_attachment` ×3 | `SecurityAudit`, `ViewOnlyAccess`, additions |

If it says anything other than "6 to add", stop and read why. A `destroy` or `change` line means Terraform found existing state you didn't expect.

**3. Create it.**

```bash
make tf-apply
```

**4. Read the credentials out.**

```bash
make tf-creds        # account ID and access key ID
make -s tf-secret    # the secret, on its own line
```

The secret is now also in `terraform/terraform.tfstate` **in plaintext**. That file is gitignored, but treat it as a credential — see [the state file warning](terraform.md#the-state-file-holds-your-secret). To avoid it entirely, set `create_access_key = false` and make the key in the console, or use role assumption.

**5. Remove it when you're done.**

```bash
make tf-destroy
```

---

### Path B — AWS Console (manual)

Slower, but you see every screen, and doing it once makes the Terraform legible. Full detail with screenshots-worth of specifics in [aws-iam-setup.md](aws-iam-setup.md).

1. **IAM → Users → Create user.** Name it `prowler-scan`. Do **not** enable console access — this identity only ever uses API keys.
2. **Attach policies directly**, and attach both:
   - `SecurityAudit`
   - `ViewOnlyAccess` — under **Job function**, which is a separate list from the main one and the usual place people get stuck
3. **Create the user.**
4. *(Optional)* Create a customer-managed policy from [`prowler-additions-policy.json`](../terraform/policies/prowler-additions-policy.json) and attach it too. Without it a handful of checks report as errors rather than pass/fail — a coverage gap, not a security gap.
5. **Open the user → Security credentials → Create access key.** Choose **Third-party service**, acknowledge the notice, create.
6. **Copy both values.** The secret is shown exactly once. Lose it and you delete the key and make another.

### Verify the identity works — before opening Prowler

Worth doing either way. A bad paste here surfaces as a confusing "Check connection" failure later.

```bash
AWS_ACCESS_KEY_ID=AKIA... \
AWS_SECRET_ACCESS_KEY=... \
aws sts get-caller-identity
```

Two things to confirm in the output:

- `Arn` ends in `user/prowler-scan` — you're testing the scanner, not your admin identity
- `Account` matches the account you intend to scan

Then prove it is genuinely read-only. This **should fail**:

```bash
AWS_ACCESS_KEY_ID=AKIA... \
AWS_SECRET_ACCESS_KEY=... \
aws iam create-user --user-name should-not-work
```

An `AccessDenied` is the correct result. If that succeeds, something broader than `SecurityAudit` + `ViewOnlyAccess` is attached and you should look at why before pointing a scanner at the account.

### Then connect it

In the Prowler UI at <http://localhost:3000>: **Settings → Providers → Add Provider → Amazon Web Services**, enter `<ACCOUNT_ID>`, choose **Credentials**, paste the key ID and secret, leave the session token blank. Full walkthrough in [README.md](README.md#step-4--connect-aws-in-the-ui).

### Cleanup, in order

1. `make tf-destroy` — or delete the key and user in the console. This alone revokes access.
2. `make purge` — removes Prowler's stored, now-dead encrypted copy of the key.
3. Delete `terraform/terraform.tfstate*` if you used Path A with a generated key.

## Glossary

| Term | Meaning |
| --- | --- |
| **Check** | One named assertion about configuration, e.g. `s3_bucket_default_encryption`. |
| **Finding** | The result of running one check against one resource: PASS, FAIL, or error. |
| **Provider** | A connected cloud account (AWS, Azure, GCP, Kubernetes, GitHub…). |
| **Scan** | One execution of all enabled checks against one provider. |
| **Severity** | The check's inherent risk rating — informational through critical. Not adjusted for your context. |
| **Compliance framework** | A published control set (CIS, NIST, PCI-DSS…) that Prowler maps findings onto. |
| **OCSF** | Open Cybersecurity Schema Framework — the normalized JSON format Prowler exports, for feeding a SIEM. |
| **Attack path** | A chain of individually-minor misconfigurations that together enable an escalation. What `neo4j` stores. |

## Going further

- Take one Critical finding and follow it end to end: read the resource, understand the exposure, remediate it, re-scan, watch it turn green. One full loop teaches more than reading a hundred findings.
- Switch the provider to **IAM role assumption**.
- Export OCSF JSON and load it somewhere queryable — the format exists so results can leave the UI.
- Add a second provider type. The check libraries differ, but every concept above transfers.
- [Prowler documentation](https://docs.prowler.com)
