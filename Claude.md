# Hands-On Walkthrough: Deploy Prowler Locally with Docker Compose and Scan Your AWS Account

> **Level:** Beginner
> **Time:** 45–60 minutes
> **Cost:** Free (Prowler is open source; scans use read-only AWS API calls that incur no meaningful cost)

---

## Introduction

In this walkthrough, you'll go from zero to a full security scan of your own AWS account using **Prowler**, one of the most popular open source cloud security tools. You'll deploy Prowler locally with Docker Compose, connect it to AWS with IAM user access keys, and run a complete account scan — all through Prowler's web UI, no command-line scanning required.

This is an introductory, hands-on experience. The goal is a working, repeatable local setup and a successful scan — not deep triage or remediation of findings (that's a topic for a follow-up).

## What is Prowler?

Prowler is an open source cloud security platform that assesses cloud environments against hundreds of security checks. For AWS alone, it runs 500+ checks across services like IAM, S3, EC2, RDS, CloudTrail, and more, and maps results to well-known frameworks such as CIS, NIST, PCI-DSS, HIPAA, and SOC 2.

Prowler comes in a few flavors:

- **Prowler CLI** — a command-line scanner
- **Prowler Local Server** (formerly "Prowler App") — a self-hosted web UI + API you run yourself, which is what we'll use
- **Prowler Cloud** — the hosted SaaS version

## Why Cloud Security Assessments Matter

Cloud accounts drift. A test bucket gets made public, an IAM user keeps keys that never rotate, logging gets disabled in one region. Most cloud breaches trace back to misconfigurations like these — not exotic exploits. Regularly assessing your account is how you catch them before someone else does.

## How You Can Use Prowler

Prowler is useful in three overlapping ways:

1. **Security reviews** — get a point-in-time picture of your account's security posture, with findings ranked by severity.
2. **Compliance-style reporting** — see how your account measures against frameworks like CIS AWS Foundations Benchmark, and download per-framework reports. Great for audits or demonstrating due diligence.
3. **Actionable misconfiguration discovery** — every failed check identifies a specific resource and what's wrong with it (e.g., "S3 bucket X has no default encryption"), giving you a concrete to-do list.

You'll touch all three by the end of this walkthrough.

---

## Prerequisites

Before starting, make sure you have:

- **Docker and Docker Compose** installed and running ([install guide](https://docs.docker.com/compose/install/)). Verify with:

  ```bash
  docker compose version
  ```

- **A personal AWS account** you own or are authorized to scan. Never scan accounts you don't have permission to assess.
- **AWS Console access** with permission to create an IAM user and access keys.
- **~4 GB of free RAM** for the Prowler containers (UI, API, worker, scheduler, PostgreSQL, Valkey).
- Ports **3000** (UI) and **8080** (API) free on your machine.

> ⚠️ **A note on IAM user access keys:** We use static access keys here because they're the simplest way to learn. For production or long-term use, Prowler recommends IAM role assumption instead. We'll delete the keys in the Cleanup section.

---

## Step 1: Deploy Prowler with Docker Compose

Prowler publishes an official `docker-compose.yml` and `.env` file for each release. Download the files matching the latest release and start the stack.

**macOS / Linux:**

```bash
mkdir prowler-local && cd prowler-local

# Get the latest release tag
VERSION=$(curl -s https://api.github.com/repos/prowler-cloud/prowler/releases/latest | jq -r .tag_name)

# Download the compose file and env file for that version
curl -sLO "https://raw.githubusercontent.com/prowler-cloud/prowler/refs/tags/${VERSION}/docker-compose.yml"
curl -sLO "https://raw.githubusercontent.com/prowler-cloud/prowler/refs/tags/${VERSION}/.env"

# Start Prowler
docker compose up -d
```

**Windows (PowerShell):**

```powershell
mkdir prowler-local; cd prowler-local

$VERSION = (Invoke-RestMethod -Uri "https://api.github.com/repos/prowler-cloud/prowler/releases/latest").tag_name
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/prowler-cloud/prowler/refs/tags/$VERSION/docker-compose.yml" -OutFile "docker-compose.yml"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/prowler-cloud/prowler/refs/tags/$VERSION/.env"  -OutFile ".env"

docker compose up -d
```

> **Why the version-matched `.env`?** Prowler's configuration lives in the `.env` file, and its contents can change between versions. Always use the `.env` that matches your `docker-compose.yml`. The defaults are fine for local learning, but don't reuse them in production.

The first launch pulls several images, so give it a few minutes. Check that everything is up:

```bash
docker compose ps
```

You should see containers for the UI, API, worker, scheduler (worker-beat), PostgreSQL, and Valkey, all in a running/healthy state. If something isn't starting, check the logs:

```bash
docker compose logs
```

## Step 2: Access the Prowler UI

Open your browser to:

```
http://localhost:3000
```

1. Click **Sign up** and create a local account with an email and password. This account exists only in your local Prowler database — it's not connected to Prowler Cloud or your AWS account.
2. Log in with the account you just created.

You'll land on an empty **Overview** page. That's expected — there's no data until you connect a provider and run a scan.

> The API's auto-generated docs are also available at `http://localhost:8080/api/v1/docs` if you're curious what's under the hood.

## Step 3: Create an IAM User and Access Keys in AWS

Prowler needs read-only credentials to inspect your account. You'll create a dedicated IAM user with the two AWS-managed policies Prowler requires.

1. Log in to the [AWS Console](https://console.aws.amazon.com) and note your **12-digit AWS Account ID** (top-right account menu) — you'll need it in the next step.
2. Go to **IAM → Users → Create user**.
3. Name it something recognizable, e.g. `prowler-scan`. Do **not** give it console access.
4. On the permissions step, choose **Attach policies directly** and attach:
   - `SecurityAudit` (AWS managed)
   - `ViewOnlyAccess` (AWS managed, under job functions)

   These grant read-only visibility across your account. Optionally, for full coverage of a small number of extra checks, you can also attach Prowler's [prowler-additions-policy.json](https://github.com/prowler-cloud/prowler/blob/master/permissions/prowler-additions-policy.json) as a customer-managed policy — not required for this walkthrough.
5. Create the user, then open it and go to **Security credentials → Create access key**.
6. Choose **Third-party service** (or "Other"), acknowledge the recommendation notice, and create the key.
7. Copy the **Access key ID** and **Secret access key** somewhere safe. The secret is shown only once.

> 🔒 These keys grant read access to your whole account. Don't commit them anywhere, don't share them, and delete them when you're done (see Cleanup).

## Step 4: Connect AWS in the Prowler UI

Back in the Prowler UI at `http://localhost:3000`:

1. Go to **Settings → Providers** (in some versions: **Configuration → Providers**).
2. Click **Add Provider**.
3. Select **Amazon Web Services**.
4. Enter your **AWS Account ID** and, optionally, a friendly alias like `my-personal-account`.
5. When asked for the authentication method, choose **Credentials** (static access keys) — not Assumed Role.
6. Paste your **Access key ID** and **Secret access key**. Leave the session token blank (only needed for temporary credentials).
7. Click **Check connection**. Prowler will verify it can authenticate to your account.

If the connection test fails, double-check that the keys were copied completely, the account ID matches the account the IAM user lives in, and the user has both managed policies attached.

## Step 5: Run a Full Account Scan

1. With the connection verified, save the provider and click **Launch Scan**.
2. Head to the **Scans** section to watch progress. A full scan runs every enabled AWS check across all regions, so expect it to take roughly 10–30 minutes depending on how many resources you have.

That's it — no check selection or region tuning needed. By default, Prowler scans the whole account, which is exactly what we want for a first baseline.

> Prowler Local Server will automatically re-scan connected providers every 24 hours while it's running, so your local setup doubles as a lightweight continuous-assessment tool.

## Step 6: Review the Scan Output at a High Level

Once the scan completes (and even while it's running), explore three sections:

- **Overview** — the big picture: total findings, pass/fail counts, and severity breakdown from your latest scan. This is your account's security posture at a glance.
- **Compliance** — your results mapped against frameworks like CIS AWS Foundations Benchmark, NIST, and PCI-DSS. Each framework shows a completion percentage, and you can download individual framework reports as CSV. This is the compliance-visibility angle in action.
- **Findings** — the detailed list of every check result. Filter by **severity** (start with Critical and High), **status** (FAIL), or **service** to see exactly which resources are misconfigured and why. Each finding names the specific resource and describes the problem — your actionable to-do list.

You can also download the complete results from the **Scans** section as a ZIP containing CSV, JSON-OCSF, and HTML reports.

Don't be alarmed by a large findings count — that's normal for any real account, and many findings are low severity. Deep triage and remediation are out of scope for this walkthrough, but a good rule of thumb: anything Critical or High involving public exposure or IAM deserves a look first.

## Step 7: Cleanup

When you're done exploring:

**Remove the AWS credentials (do this even if you keep Prowler running):**

1. In the AWS Console, go to **IAM → Users → prowler-scan → Security credentials**.
2. Deactivate and **delete the access key**.
3. If you don't plan to scan again soon, delete the `prowler-scan` user entirely. You can always recreate it later.

**Stop Prowler:**

```bash
docker compose down
```

This stops the containers but keeps your scan data in Docker volumes, so `docker compose up -d` brings everything back — accounts, providers, and past scan results included.

**Full teardown (optional):** to also delete all stored data, including scan history and the credentials Prowler stored:

```bash
docker compose down -v
```

## Conclusion

You've deployed a complete cloud security assessment platform on your own machine, connected it to AWS with read-only credentials, run a full account scan, and reviewed the results from three perspectives: overall security posture, compliance framework coverage, and concrete misconfigurations.

Because the whole stack is just a `docker-compose.yml` and a `.env` file, this setup is repeatable — you can tear it down and rebuild it in minutes, or leave it running for automatic daily scans.

**Where to go next:**

- Dig into triaging findings: filter by severity, investigate a Critical finding end-to-end, and remediate it
- Switch authentication from access keys to the recommended **IAM role assumption** for a more production-ready setup
- Explore the [Prowler documentation](https://docs.prowler.com) for other providers (Azure, GCP, Kubernetes, GitHub, and more)
