# Issue log

Known problems and deviations, tracked. [troubleshooting.md](troubleshooting.md) tells you how to *fix* things that go wrong on your machine; this file records what is *known to be wrong or divergent* in the project itself.

Status: **open** (unresolved) · **accepted** (won't fix, reasons given) · **fixed** (resolved, kept for history).

Last reviewed against Prowler **5.38.0**.

---

## Doc drift: Claude.md vs. the pinned release

The walkthrough at the repo root was written against an earlier Prowler release. Three of its statements are no longer accurate for 5.38.0. The project follows the compose file, not the walkthrough.

### DOC-1 — Stack size understated · **open**

`Claude.md` says the stack is "UI, API, worker, scheduler, PostgreSQL, Valkey" — six services. 5.38.0 also runs **`neo4j`** (dozerdb, for attack-path graphs) and **`mcp-server`**, for eight long-running services plus a one-shot `api-init`.

*Impact:* users following the walkthrough expect fewer containers than `docker compose ps` shows, and may read the extras as an error.

*Handled by:* the service table in [README.md](README.md).

### DOC-2 — RAM requirement understated · **open**

`Claude.md` says "~4 GB of free RAM". neo4j alone is configured for 1 GB heap + 1 GB page cache (`NEO4J_SERVER_MEMORY_HEAP_MAX__SIZE`, `NEO4J_SERVER_MEMORY_PAGECACHE_SIZE`), on top of seven other services.

*Measured:* **5.4 GiB resident at idle**, all eight services up, no scan running — `worker` 2.0 GiB, `api` 1.4 GiB, `neo4j` 1.3 GiB. A 4 GB allocation cannot hold this.

*Impact:* on a 4 GB Docker allocation, neo4j is the first thing the OOM killer takes, and the failure surfaces confusingly as the UI never starting (see ENV-1).

*Handled by:* `preflight.sh` warns below 6 GB and fails below 4 GB; [README.md](README.md) states 6 GB with the measured breakdown.

### DOC-3 — `docker compose down -v` does not delete data · **open**

`Claude.md` presents `down -v` as full teardown. In 5.38.0, postgres, valkey, neo4j and the API config are **bind-mounted to `./_data/`**, not stored in named volumes. Only the `output` volume is named. `-v` leaves `_data/` completely intact.

*Impact:* a user who believes they wiped everything still has their findings, their local account, and their **encrypted AWS credentials** on disk. This is the highest-consequence item in this file — it's a privacy expectation that silently doesn't hold.

*Handled by:* `make purge` / `teardown.sh --purge` removes `_data/` as well as running `down -v`.

---

## Environment and runtime

### ENV-1 — An unhealthy `mcp-server` blocks the UI entirely · **accepted (upstream design)**

`ui` declares `depends_on: mcp-server: condition: service_healthy`. If the MCP server is unhealthy, the UI container never starts, so the symptom is "localhost:3000 refuses connections" with nothing in the UI logs to explain it.

*Workaround:* check `docker compose ps` and `make logs S=mcp-server` first. Documented at the top of [troubleshooting.md](troubleshooting.md).

*Won't fix:* changing the dependency means editing the upstream compose file, which `make setup`/`make upgrade` overwrite.

### ENV-2 — Six published host ports, several on common defaults · **accepted**

The stack binds 3000, 8000, 5432, 6379, 7687 and 8080. Postgres on 5432 and valkey on 6379 collide with locally-installed instances, which is the most common first-run failure.

*Workaround:* `preflight.sh` checks all six before starting; [troubleshooting.md](troubleshooting.md) covers remapping via `.env`.

*Note:* `mcp-server`'s port 8000 is hardcoded in `docker-compose.yml` and not driven by `.env`, so remapping it means editing a file that upgrades overwrite.

### ENV-3 — Ports bind to all interfaces, with default passwords · **open**

Compose publishes ports without a `127.0.0.1:` prefix, so postgres (password `postgres`) and neo4j (`neo4j_password`) are reachable from anything that can route to the host.

*Impact:* fine on a laptop behind a firewall; not fine on a shared box, a VPS, or a café network.

*Mitigation for now:* documented in README's security notes. A real fix means overriding the port bindings, which upgrades would overwrite — a `docker-compose.override.yml` is the natural home for it but isn't written yet.

### ENV-4 — Changing postgres credentials after first start has no effect · **accepted (postgres behavior)**

`POSTGRES_USER`/`POSTGRES_PASSWORD` are only read when postgres initializes its data directory. Editing them in `.env` later leaves the database with the old credentials while the API tries the new ones, and the API fails at migration time.

*Workaround:* match `.env` to the original values, or `make purge` and start clean. In [troubleshooting.md](troubleshooting.md).

---

## Credentials and secrets

### SEC-1 — Upstream `.env` ships published secret keys · **fixed**

The released `.env` contains literal default values for `AUTH_SECRET` and `DJANGO_SECRETS_ENCRYPTION_KEY`. The latter encrypts the cloud credentials Prowler stores in postgres, so the default offers no protection against anyone who has read the public repo.

*Fixed by:* `scripts/rotate-secrets.sh` (`make secrets`), run as a documented step before connecting AWS. `preflight.sh` warns whenever either default is detected.

### SEC-2 — Rotating the encryption key orphans stored credentials · **accepted**

Rotating `DJANGO_SECRETS_ENCRYPTION_KEY` after a provider is saved makes the stored AWS secret undecryptable; it must be re-entered in the UI.

*Mitigation:* `rotate-secrets.sh` refuses to run if `_data/postgres` exists unless given `--force`, and `make upgrade` reminds you to carry the key across from `.env.bak`.

### SEC-3 — Deleting the AWS key doesn't remove it from Prowler · **open**

After you delete the access key in IAM (the documented cleanup step), the encrypted copy remains in postgres until `make purge`. It's dead material — the key no longer authenticates — but it is still stored.

*Handled by:* noted in [aws-iam-setup.md](aws-iam-setup.md#cleanup).

### SEC-4 — Default-secret detection is version-pinned · **open**

`preflight.sh` detects the shipped defaults by matching the literal 5.38.0 values. If upstream changes its defaults in a future release, the check reports "changed from default" for a value that is still a published default.

*Impact:* a false negative on a security check, silently. Re-verify the matched strings after each `make upgrade`.

---

## Tooling in this repo

### TOOL-1 — Backup filename collision between scripts · **fixed**

`setup.sh` and `rotate-secrets.sh` both wrote `.env.bak`, so running `make setup` after `make secrets` overwrote the only copy of the pre-rotation file.

*Fixed by:* `rotate-secrets.sh` now writes `.env.pre-rotate.bak`.

### TOOL-2 — Command substitution in `teardown.sh` echo · **fixed**

Two `echo` lines used backticks inside double quotes to typeset `` `make up` ``, which bash evaluates as command substitution — the teardown script would have re-launched the stack it had just stopped.

*Fixed by:* single-quoting both lines. Caught before any run.

### TOOL-3 — Scripts are macOS-only · **open**

`rotate-secrets.sh` uses BSD `sed -i ''` (GNU sed reads `''` as the script argument and errors). `preflight.sh` uses `df -g` (BSD; Linux needs `-BG`) and `lsof` for port checks.

*Impact:* the scripts fail or silently skip checks on Linux. Acceptable for now — this project targets a macOS workstation — but it is a real portability limit, not a design choice.

### TOOL-4 — `make status` reports once, doesn't wait · **accepted**

The target curls the UI and API a single time and reports. During the multi-minute first start it will say "not ready yet" repeatedly and you re-run it by hand.

*Won't fix for now:* a polling loop needs a timeout and clean interrupt handling; re-running one command is a fair trade. The help text says "single check, not a wait" so the name doesn't mislead.

### TOOL-5 — `.prowler-version` pins a tag, not a digest · **accepted**

The pin controls which `docker-compose.yml`/`.env` are fetched, but those files reference images by *mutable* tags (`prowlercloud/prowler-api:stable`). Two `make up` runs weeks apart can pull different images from the same pinned version.

*Mitigation:* pin `PROWLER_API_VERSION`/`PROWLER_UI_VERSION`/`PROWLER_MCP_VERSION` in `.env` to explicit versions instead of `stable` if you need reproducibility. Note the infrastructure images (postgres, valkey, neo4j, busybox) *are* digest-pinned upstream — only Prowler's own images float.

---

---

## Terraform

### TF-1 — Access key secret is stored in Terraform state in plaintext · **open**

`aws_iam_access_key` returns the secret once, and Terraform persists it to `terraform.tfstate` unencrypted. Marking the output `sensitive` suppresses console display but does nothing to the file.

*Impact:* `terraform.tfstate` becomes a credential file granting account-wide read access. A shared or unencrypted remote backend would publish it.

*Mitigations:* `*.tfstate*` gitignored; `create_access_key = false` creates the user without a key; `auth_method = "role"` avoids long-lived secrets entirely. Documented prominently in [terraform.md](terraform.md#the-state-file-holds-your-secret).

*Won't fully fix:* inherent to the resource. The `pgp_key` argument would encrypt it at rest but requires a GPG keypair and adds a decrypt step — disproportionate for a learning setup, and worth revisiting if this is ever used with a remote backend.

### TF-2 — Vendored additions policy drifts from the pinned release · **open**

`terraform/policies/prowler-additions-policy.json` is a verbatim copy taken at 5.38.0. `make upgrade` bumps Prowler but does not re-fetch this file, so new checks added upstream will silently lack permissions.

*Symptom:* checks reporting as errors rather than pass/fail after an upgrade.

*Workaround:* the re-fetch command in [terraform.md](terraform.md#what-gets-created). Automating it inside `setup.sh` would mean the script mutating Terraform-managed files, which is worse — so this stays a documented manual step.

### TF-5 — Saved plan files were not gitignored · **fixed**

`.gitignore` had `*.tfplan`, which does not match a file named plain `tfplan` — and `-out=tfplan` is the common habit. After the first real apply, `terraform/tfplan` showed up as untracked in a **public** repo, one `git add -A` away from being committed.

*Checked:* this particular plan did **not** contain the access key secret, because the key was `(known after apply)`. But plan files can embed sensitive variable values and the full prior state, so they should never be tracked regardless.

*Fixed:* `.gitignore` now carries both `tfplan` and `*.tfplan`; the stale file was removed and the rule verified with `git check-ignore`.

### TF-3 — `terraform destroy` fails if the user was modified out of band · **accepted (deliberate)**

`force_destroy = false` on the IAM user means destroy fails if someone attached extra policies or a second access key through the console.

*Rationale:* the alternative silently discards access paths Terraform didn't create. A failed destroy that makes you look is the safer default. Override by removing the extra attachments yourself, not by flipping the flag.

### TF-4 — Role-mode precondition verified against a live account · **fixed**

Role mode with an empty `trusted_principal_arns` is guarded by a `lifecycle.precondition` on `aws_iam_role`.

*Verified* against account `907992937591`: the precondition fires at **plan** time, before any API call, and prints the intended message naming the variable. Role mode with a valid principal plans cleanly (5 to add) and renders the `sts:ExternalId` condition correctly. Credentials mode plans 6 to add.

*Confirmed separately:* without the guard, the trust policy renders as `"Principal": {"AWS": []}`, which AWS rejects at apply with `MalformedPolicyDocument`.

---

## CI

### TOOL-6 — `curl` glob-parsed the JSON:API filter brackets · **fixed**

`make mutelist` failed with a bare `make: *** [mutelist] Error 3`.

Cause: JSON:API filters are bracketed — `?filter[processor_type]=mutelist` — and `curl` treats `[...]` as a **glob range** by default. It refused to build the URL and never contacted the server:

```
curl: (3) bad range in URL position 48
```

Two things made this hard to read. The failure is client-side, so "could not reach the API" was actively misleading — the server was healthy. And `curl -f` plus `set -e` meant the script died on curl's raw exit code before printing anything, so `make` surfaced only the number.

*Fixed:* `-g` (`--globoff`) on every API call, plus error handling that prints curl's own message rather than just its status. Any future bracketed filter would have hit the same wall.

### CI-1 — Bump PRs don't trigger their own checks · **accepted**

`upstream-release.yml` pushes with `GITHUB_TOKEN`, and GitHub deliberately does not trigger workflows from token-authored pushes (it prevents recursive runs). So `ci.yml` does not run on the bump PR.

*Workaround:* close and reopen the PR, or push an empty commit. The generated PR body says so.

*Won't fix:* the alternatives are a PAT or a GitHub App, both of which mean managing another credential for a weekly convenience.

### CI-2 — Three checkov findings are suppressed · **accepted (documented)**

`CKV_AWS_273` (IAM user rather than SSO) and `CKV_AWS_40` ×2 (policies attached to a user rather than a group) fire on `auth_method = "credentials"`.

*Rationale:* the findings are correct, and the remedy for all three is `auth_method = "role"` — which the project already recommends. Suppressed with inline `checkov:skip` comments carrying written justifications in `terraform/iam_user.tf`, so they surface in code review. Anything new fails the build.

*Re-examine* if the `credentials` path ever stops being framed as a learning shortcut.

### CI-3 — `preflight.sh` is not exercised by CI · **open**

It's excluded because BSD `df -g` would silently skip the disk check on Linux, making a skipped check look like a passed one. The consequence is that `preflight.sh` has no automated coverage at all beyond `bash -n` and shellcheck.

*Fix when [TOOL-3](#tool-3--scripts-are-macos-only--open) is fixed* — a portable preflight could run in CI and be genuinely tested.

### CI-4 — Terraform plan coverage is opt-in and unset · **open**

`terraform-plan.yml` no-ops until `AWS_PLAN_ROLE_ARN` is set, so out of the box nothing ever runs `terraform plan` against a real account. That leaves [TF-4](#tf-4--role-mode-precondition-verified-against-a-live-account--fixed) unexercised in CI, though it has since been verified by hand.

*Mitigation:* offline `validate` and `console` checks still run on every PR. Setting up OIDC closes the gap — see [ci.md](ci.md#terraform-planyml--opt-in-prs-touching-terraform).

---

## Reporting something new

Add an entry with an ID in the existing scheme (`DOC-`, `ENV-`, `SEC-`, `TOOL-`), a status, the concrete impact, and either the workaround or where it's handled. Move entries to **fixed** rather than deleting them — the history is what stops a fixed bug from being reintroduced on the next upgrade.
