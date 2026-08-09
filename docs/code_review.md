# Code review

Review of the tooling in this repo — the `Makefile`, the four scripts in [`scripts/`](../scripts), and the Terraform in [`terraform/`](../terraform). Findings that became tracked items are cross-referenced to [issue.md](issue.md).

Reviewed against Prowler **5.38.0** on macOS (bash 3.2, BSD userland, Docker Desktop 2.40.3).

**Scope note:** this reviews *our* wrapper only. `docker-compose.yml` and `.env` are fetched verbatim from upstream and are not ours to review — see [Out of scope](#out-of-scope).

---

## Verification performed

| Check | Result |
| --- | --- |
| `bash -n` on all four scripts | pass |
| `shellcheck scripts/*.sh` | 1 warning, 7 info — all triaged below |
| `docker compose config -q` | valid, before and after secret rotation |
| `make help` renders | pass |
| `preflight.sh` end-to-end | pass — correctly failed on a stopped Docker daemon |
| `rotate-secrets.sh` end-to-end | pass — both keys replaced, `.env` still parses |
| `set -e` behavior of guarded `cp` in `setup.sh:40` | verified non-fatal in an isolated repro |
| base64 `/` `+` `&` survive `sed` replacement | verified in an isolated repro |
| `terraform fmt -check -recursive` | clean |
| `terraform init` + `terraform validate` | pass |
| Empty `principals.identifiers` behavior | verified in an isolated repro — renders `"AWS": []` |
| Vendored additions policy is valid JSON | pass |
| Workflow YAML parses (all 4 files) | pass |
| `bash -n` on all 19 embedded `run:` blocks | pass |
| `shellcheck --severity=warning` on embedded `run:` blocks | clean |
| `checkov -d terraform` | 27 passed, 0 failed, 3 documented skips |
| `scripts/check-docs.py` | pass — 8 files, 47 internal links |
| `make ci` end-to-end | pass |

Not executed: `make up`, `make down`, `make purge` — all require a running Docker daemon and, for purge, real data to destroy. `terraform plan`/`apply` were not run against a live account; provider credential validation fails first without real AWS credentials.

---

## Findings

### 1. `preflight.sh` continued after a failed `cd` — **fixed**

`shellcheck` SC2164. Every script starts with `cd "$(dirname "$0")/.."` to reach the project root. Three of them run under `set -e`, so a failed `cd` aborts. `preflight.sh` deliberately runs under `set -uo pipefail` **without `-e`** — it needs to collect every problem before exiting — which made it the one script where a failed `cd` would silently continue.

*Failure scenario:* run from a directory the user can't traverse, and preflight checks `.env`/`docker-compose.yml` in the wrong directory, reporting them missing (or worse, present) based on unrelated files.

*Fix:* explicit `|| { echo ...; exit 1; }` guard, with a comment recording why the guard is load-bearing here and not elsewhere.

### 2. Backticks inside double quotes in `teardown.sh` — **fixed**

Two `echo` lines typeset `` `make up` `` for the reader using backticks, inside double quotes:

```bash
echo "Purged. `make up` will start from a clean database."
```

Bash evaluates that as command substitution. The teardown script would have **re-launched the stack it had just torn down**, and in the `--purge` path would have done so immediately after deleting the database — recreating `_data/` seconds after the user confirmed its destruction.

*Fix:* single quotes on both lines. `shellcheck` now reports SC2016 ("expressions don't expand in single quotes") on them, which is precisely the intent — accepted, not suppressed.

Tracked as [TOOL-2](issue.md#tool-2--command-substitution-in-teardownsh-echo--fixed).

### 3. Both scripts wrote `.env.bak` — **fixed**

`setup.sh` backs up `.env` before overwriting it; `rotate-secrets.sh` did the same, to the same filename.

*Failure scenario:* `make secrets` (writes `.env.bak` = upstream defaults), then later `make setup` (writes `.env.bak` = your rotated file, overwriting the previous backup). Recoverable, but the "backup" silently stops being what its name implies.

The consequence is worse than a lost file: `make upgrade` tells you to diff `.env.bak` against the new `.env` to carry your encryption key across. If that backup was clobbered, the key is gone and the stored AWS credentials become undecryptable.

*Fix:* `rotate-secrets.sh` writes `.env.pre-rotate.bak`. Tracked as [TOOL-1](issue.md#tool-1--backup-filename-collision-between-scripts--fixed).

### 4. Misleading comment on `sed` escaping — **fixed**

`rotate-secrets.sh` claimed to "escape `/`, `&` and `+`". It escaped `\`, `&` and `/`, and never touched `+`.

The *code* was correct — `+` is literal in a `sed` replacement, and `/` needs no escaping given the `|` delimiter, so escaping it was harmless-but-redundant. Only the comment was wrong, which is the kind of thing that misleads the next person editing the escaping logic.

*Fix:* dropped the redundant `/` escape, corrected the comment to say what the code does and why.

### 5. `make status` named as if it waits — **fixed (wording)**

The Makefile help read "Wait for the UI and API to report healthy". The target curls each endpoint exactly once. During a multi-minute first start it reports "not ready yet" and exits, so a user taking the help text literally would think the wait had completed and the stack had failed.

*Fix:* help text now reads "single check, not a wait". A polling loop needs timeout and interrupt handling; re-running one command is a fair trade for now. Tracked as [TOOL-4](issue.md#tool-4--make-status-reports-once-doesnt-wait--accepted).

### 6. Service count wrong in two places — **fixed**

`README.md` prose and a `preflight.sh` comment said "seven services" while README's own table listed eight rows. The compose file defines nine services: eight long-running plus the one-shot `api-init`.

Minor as a fact, but it sat directly next to the RAM guidance it was justifying, so the reasoning didn't add up on inspection.

*Fix:* both corrected to "eight long-running services"; [learn.md](learn.md) notes the `api-init` distinction.

### 7. Scripts are macOS-only — **open, accepted for now**

Three BSD-isms, none of which fail loudly on Linux:

| Location | Construct | Behavior on GNU/Linux |
| --- | --- | --- |
| `rotate-secrets.sh` | `sed -i ''` | Errors — GNU sed reads `''` as the script |
| `preflight.sh` | `df -g` | Invalid option; disk check silently skipped |
| `preflight.sh` | `lsof -nP -iTCP` | Usually present, but not guaranteed installed |

The `df` case is the one that bothers me: it's guarded by `[[ -n "${avail_gb:-}" ]]`, so on Linux the disk check silently *disappears* rather than reporting that it couldn't run. A skipped check that looks like a passed check is the failure mode preflight exists to prevent.

Accepted because this project targets a macOS workstation and the pinned-version workflow makes the target environment explicit. Tracked as [TOOL-3](issue.md#tool-3--scripts-are-macos-only--open).

### 8. Default-secret detection is pinned to literal 5.38.0 values — **open**

`preflight.sh` detects unrotated secrets by matching the exact base64 strings shipped in 5.38.0's `.env`. If upstream changes those defaults, the check reports "changed from default" for a value that is still a published default.

This is a security check that fails *open* and silently. It can't be fixed generically — there's no marker distinguishing "upstream default" from "user value" — so the mitigation is procedural: re-verify the matched strings after each `make upgrade`. Tracked as [SEC-4](issue.md#sec-4--default-secret-detection-is-version-pinned--open).

---

### 9. Terraform: invalid `precondition` blocked `init` — **fixed**

The first cut guarded role-mode inputs with a `terraform_data` resource carrying `condition = false`. Terraform rejects that outright: a precondition expression must reference at least one object, or it isn't checking anything. `terraform init` failed before it could install providers.

*Fix:* moved the guard onto `aws_iam_role` itself, where it references `var.trusted_principal_arns`. Better placement anyway — it now fires only in the mode where it applies, and keeps `required_version` at 1.5 rather than needing 1.9 for cross-variable validation.

*Worth noting the failure mode it prevents:* I confirmed in an isolated harness that `aws_iam_policy_document` accepts an empty `identifiers` list and renders `"Principal": {"AWS": []}` without complaint. AWS then rejects it at apply with `MalformedPolicyDocument`. Without the guard, an easy mistake produces an error that names neither the variable nor the cause. Tracked as [TF-4](issue.md#tf-4--role-mode-precondition-unverified-against-a-live-account--open).

### 10. Terraform: guidance output leaked sensitivity — **fixed**

`output "next_steps"` interpolated `var.external_id != ""` to decide what to print. Comparing against a `sensitive` variable produces a sensitive result, so Terraform refused to plan until the whole output was marked sensitive — which would have hidden all the setup guidance, including the non-secret account ID and role ARN.

*Fix:* a `local.has_external_id` computed with `nonsensitive()`. Whether an external ID exists isn't a secret; its value is, and that stays in a separate `sensitive` output. This is the right shape — the alternative, marking `next_steps` sensitive wholesale, would have made the useful output unreadable and taught users to reach for `-raw` on everything.

### 11. Broken doc anchor found by the new checker — **fixed**

`scripts/check-docs.py` failed on its first run against a link I had hand-written: `terraform.md#️-the-state-file-holds-your-secret`.

The target heading was `## ⚠️ The state file holds your secret`. GitHub's slug algorithm strips the `⚠` but **keeps** the invisible U+FE0F variation selector, producing an anchor that starts with a zero-width character. Different renderers disagree about this.

*Fix:* moved the emoji out of the heading into the body text. Teaching the checker GitHub's quirk would have preserved a fragile anchor; removing the cause makes it portable. This is why the checker exists — 47 hand-written internal links, none previously verified.

### 12. Indented heredoc in a workflow `run:` block — **fixed**

The release-watcher's PR body used `--body "$(cat <<EOF … EOF)"` with the terminator indented. My first read was that this would break, since `<<EOF` needs the terminator at column 0.

On closer inspection it would in fact have worked: a YAML block scalar strips the common indentation before bash sees the script, so the terminator lands at column 0 anyway. The rewrite to `--body-file` was kept regardless — it survives someone later re-indenting the YAML, which the original would not.

*Method note:* this was caught by parsing every workflow with a YAML library and running `bash -n` on each of the 19 embedded `run:` blocks, then `shellcheck` over the same blocks with `${{ }}` expressions substituted out. Worth doing — workflow shell is otherwise unlinted until it fails in CI.

## Triaged and not changed

**`shellcheck` SC2015 (`A && B || C` is not if-then-else)** — 6 instances in `preflight.sh`, all of the form `check && ok "..." || bad "..."`. The warning is that `C` also runs if `B` fails. Here `B` is always `ok`/`note`/`bad`, whose last statement is a `printf` or a variable assignment, both of which return 0. The pattern is safe as written and reads better than six `if` blocks. Not changed, but it's a latent trap: adding a failure path to `ok()` would quietly make every one of these double-report.

**`shellcheck` SC2016 in `teardown.sh`** — intentional, and the fix for finding 2. Not suppressed, because a suppression comment would hide a genuine warning if someone later added a real variable to those strings.

**`setup.sh:40`, guarded `cp` under `set -e`** — `[[ -f docker-compose.yml ]] && cp ...` looked like it could abort the script when the file doesn't exist. It can't: bash exempts non-final commands in an `&&` list from `-e`. Verified with an isolated repro rather than trusting the reasoning. No change.

**`teardown.sh` root-owned `_data/` fallback** — when `rm -rf` fails on container-owned paths, it retries inside a busybox container with `-v "$PWD:/work"`. This project's path contains spaces; the quoting is correct. No change.

---

## Design decisions worth stating

**`.env` is gitignored, `.prowler-version` is committed.** `.env` holds the key that encrypts your AWS credentials, so it can't be tracked. Committing the version pin instead means `make setup` reproduces the exact `.env`/`docker-compose.yml` pair without the repo ever holding a secret. `*.bak` is also ignored — `.env.bak` contains old secrets by definition.

**`make up` depends on `preflight`.** Prerequisites run before the recipe, so a port conflict or missing file stops you before `docker compose up` produces a wall of container errors. Costs a second.

**`rotate-secrets.sh` refuses to run once `_data/postgres` exists.** Rotating the encryption key after a provider is saved makes the stored credential undecryptable. The guard fails closed and explains the `--force` escape hatch rather than making the destructive path the easy one.

**`purge` asks for a typed word, not `y/N`.** It deletes scan history and stored credentials with no undo. Typing `purge` is a deliberate speed bump.

---

## Out of scope

- **`docker-compose.yml` and `.env`** — fetched verbatim from upstream. Their properties are recorded as environment issues in [issue.md](issue.md) (`ENV-1`…`ENV-4`) rather than as review findings here, since the fix would be overwritten by the next `make setup`.
- **Prowler's own code and check library** — upstream.
- **The AWS IAM policy choices** — `SecurityAudit` + `ViewOnlyAccess` are what upstream documents; see [aws-iam-setup.md](aws-iam-setup.md). The vendored `prowler-additions-policy.json` is upstream's file verbatim; its contents weren't audited action-by-action, only confirmed to be read-only in shape and valid JSON.

## Residual risk

**In the Terraform:** [TF-1](issue.md#tf-1--access-key-secret-is-stored-in-terraform-state-in-plaintext--open) — `auth_method = "credentials"` writes the secret access key to `terraform.tfstate` in plaintext. That's inherent to `aws_iam_access_key`, not a choice this config made, and it's mitigated by gitignoring state, offering `create_access_key = false`, and offering role mode. But it means the default path produces a second copy of an account-wide read credential in a file people don't instinctively treat as secret. Anyone moving this to a remote backend must encrypt it.

**Overall**, the highest-consequence open item is not in this repo's code. It's [ENV-3](issue.md#env-3--ports-bind-to-all-interfaces-with-default-passwords--open): the compose file publishes postgres and neo4j on all interfaces with default passwords. On a laptop behind a firewall that's acceptable; on a shared or internet-reachable host it is not, and nothing in the current tooling prevents someone from running `make up` there. A `docker-compose.override.yml` binding ports to `127.0.0.1` would fix it without being clobbered by upgrades. That's the next thing I'd add.
