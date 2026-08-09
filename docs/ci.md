# Continuous integration

Three workflows in [`.github/workflows/`](../.github/workflows), plus Dependabot.

Run the offline half locally before pushing:

```bash
make ci
```

> **This project is not a git repository yet.** The workflows are in place but nothing runs until you `git init`, commit, and push to GitHub. See [Turning it on](#turning-it-on).

---

## `ci.yml` — on every push and PR

Five jobs, run in parallel.

| Job | What it checks |
| --- | --- |
| **Shell scripts** | `bash -n` plus `shellcheck --severity=warning` on `scripts/*.sh` |
| **Documentation** | `scripts/check-docs.py` — layout convention, relative links, `#anchors` |
| **Terraform** | `fmt -check`, `init -backend=false`, `validate`, role-mode evaluation, policy JSON |
| **Terraform security scan** | `checkov` against `terraform/` |
| **Compose stack** | Fetches the pinned release and validates `docker-compose.yml` |

Three of these deserve explanation.

**The documentation job enforces the project convention** that all markdown lives in `docs/` except `Claude.md`. It also resolves every relative link and heading anchor — 47 of them at the time of writing, all hand-written and therefore all suspect. It found a genuinely broken anchor the first time it ran: a `⚠️` in a heading, where GitHub keeps the invisible variation-selector codepoint in the slug. The fix was to keep emoji out of headings rather than teach the checker that quirk.

**The compose job is a real integration test, not a lint.** `docker-compose.yml` and `.env` are gitignored, so CI fetches them exactly as a user does, by running `scripts/setup.sh`. That means CI fails if the pinned tag's files are moved, renamed or withdrawn upstream — which is the failure a user would otherwise hit on their first `make setup`.

**The security scan passes with three documented suppressions.** Checkov flags the `credentials` mode for using an IAM user (`CKV_AWS_273`) and for attaching policies directly to a user rather than a group (`CKV_AWS_40`, twice). Those findings are correct, and the answer to all three is "use `auth_method = "role"`" — which is exactly what [terraform.md](terraform.md) recommends. The suppressions are inline `checkov:skip` comments in [`terraform/iam_user.tf`](../terraform/iam_user.tf) with written justifications, so they show up in code review instead of hiding in a config file. Anything new fails the build.

`preflight.sh` is deliberately **not** run in CI. It uses BSD `df -g`, which on Linux would silently skip the disk check — a skipped check that looks like a passed one is the exact failure mode preflight exists to prevent. See [TOOL-3](issue.md#tool-3--scripts-are-macos-only--open).

## `upstream-release.yml` — Mondays, 07:00 UTC

Compares [`.prowler-version`](../.prowler-version) against Prowler's latest GitHub release. If they differ, it opens a PR that does two things together:

1. Re-pins `.prowler-version`.
2. Re-fetches `terraform/policies/prowler-additions-policy.json` for the new tag.

The second is the point. That policy is vendored, and its action list grows as upstream adds checks — so without this, an upgrade silently under-permissions the scanner and the new checks report as errors rather than pass/fail. That's [TF-2](issue.md#tf-2--vendored-additions-policy-drifts-from-the-pinned-release--open), and this workflow is the fix.

Nothing upgrades automatically. The PR carries a checklist covering the things that bite on an upgrade — carrying your rotated `AUTH_SECRET` and `DJANGO_SECRETS_ENCRYPTION_KEY` across ([SEC-2](issue.md#sec-2--rotating-the-encryption-key-orphans-stored-credentials--accepted)), and re-verifying that `preflight.sh`'s default-secret strings still match what upstream ships ([SEC-4](issue.md#sec-4--default-secret-detection-is-version-pinned--open)).

It re-runs weekly, so it checks for an existing open PR on the same branch first rather than stacking duplicates.

> **Known limitation:** PRs pushed with `GITHUB_TOKEN` do not trigger other workflows, so `ci.yml` won't run on the bump PR automatically. Close and reopen it, or push an empty commit. The PR body says so. Using a PAT or a GitHub App would fix it at the cost of managing another credential.

## `terraform-plan.yml` — opt-in, PRs touching `terraform/`

Runs a real `terraform plan` against AWS and posts it as a PR comment.

**It no-ops unless you set it up**, so it's harmless if you never do: the first step checks for the repository variable `AWS_PLAN_ROLE_ARN` and skips everything if it's unset. Offline validation in `ci.yml` covers the config either way.

To enable it:

1. Create a GitHub OIDC identity provider in your AWS account.
2. Create a role trusting this repository, with read-only IAM permissions (`iam:Get*`, `iam:List*`) so a plan can refresh state.
3. Set the repo variable `AWS_PLAN_ROLE_ARN` to that role's ARN. Optionally set `AWS_REGION`.

Two deliberate choices:

- **Plan only, never apply.** Creating IAM identities should be a decision someone makes at a terminal, not a side effect of opening a PR.
- **Planned with `create_access_key=false`.** No secret is generated, so none can reach the workflow log or the PR comment. This is the same reasoning as [TF-1](issue.md#tf-1--access-key-secret-is-stored-in-terraform-state-in-plaintext--open) — the safest secret is the one that was never created.

OIDC token exchange is done with `curl` and `aws sts assume-role-with-web-identity` rather than pulling in another third-party action.

## Supply chain

Third-party actions are pinned to **commit SHAs**, not tags:

```yaml
uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
```

Tags are mutable. A compromised action repository could repoint `v4` at anything, and every workflow using it would pick that up on the next run. The SHA can't be repointed. The trailing comment records which tag it corresponded to, and Dependabot understands that convention well enough to update both.

Only three actions are used — `actions/checkout`, `actions/setup-python`, `hashicorp/setup-terraform`. Everything else is `curl`, `jq`, `gh`, `shellcheck` and `docker compose`, all preinstalled on `ubuntu-latest`.

`permissions` defaults to `contents: read` at the workflow level, and jobs elevate only what they need — `contents: write` and `pull-requests: write` for the release watcher, `id-token: write` for OIDC.

## `dependabot.yml`

Weekly PRs for GitHub Actions SHAs and the Terraform AWS provider constraint.

Three things it deliberately does **not** cover, with the reasons in the file itself: the pinned Prowler release and vendored policy (handled by `upstream-release.yml`, which bumps them together), the container images in `docker-compose.yml` (fetched at setup time and gitignored — there's nothing tracked to update), and the checkov version in `ci.yml` (an env var, not a manifest Dependabot can parse).

## Turning it on

```bash
git init
git add .
git commit -m "Initial commit: Prowler local server with Docker Compose"
gh repo create prowler-with-docker --private --source=. --push
```

Before that first commit, confirm nothing sensitive is staged. `.env`, `_data/`, `*.tfstate*`, `terraform.tfvars` and `*.bak` are all gitignored, but the check is cheap:

```bash
git status --short
git check-ignore -v .env terraform/terraform.tfstate terraform/terraform.tfvars
```

If `.env` shows up in `git status`, stop and fix `.gitignore` before committing — it holds the key that encrypts your stored AWS credentials.

## Local equivalents

```bash
make ci           # lint + docs-check + tf-check + checkov
make lint         # bash -n and shellcheck
make docs-check   # markdown layout, links, anchors
make tf-check     # terraform fmt and validate
```

`make ci` skips `shellcheck` and `checkov` with a note if they aren't installed, rather than failing — CI is the backstop that always runs them. Install both with `brew install shellcheck` and `pip install checkov`.
