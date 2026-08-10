# Terraform: provisioning the AWS side

[`terraform/`](../terraform) creates the read-only IAM identity Prowler scans with — the same thing [aws-iam-setup.md](aws-iam-setup.md) walks through by hand in the console, but reproducible and destroyable in one command.

Click-ops is fine for a first run. Terraform earns its place the second time: it gets the `ViewOnlyAccess` job-function path right, attaches the supplementary policy most people skip, and — most importantly — makes cleanup a single command instead of a checklist you might forget.

**Requires:** Terraform ≥ 1.5, and AWS credentials in your shell with permission to create IAM users/roles (your normal admin identity, not the scanner's).

---

## Which auth method

| | `credentials` (default) | `role` |
| --- | --- | --- |
| Creates | IAM user + access key | IAM role |
| Prowler UI setting | Credentials | Assumed Role |
| Long-lived secret | Yes | No |
| Secret in Terraform state | **Yes, plaintext** | No |
| Matches the walkthrough | Yes | No |
| Good for | Learning, one-off scans | Anything ongoing |

Start with `credentials` if you're following the walkthrough. Move to `role` once it works — that's the whole point of the "where to go next" section in [README.md](README.md).

## Quick start

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars

make tf-init
make tf-plan          # read this before applying
make tf-apply
make tf-creds         # account ID + key ID
make -s tf-secret     # the secret, on its own
```

Then paste the values into the Prowler UI as described in [README.md](README.md#step-5--connect-aws-in-the-ui).

When you're finished scanning:

```bash
make tf-destroy
```

That deletes the access key and the user — the cleanup step people forget.

## The state file holds your secret

⚠️ With `auth_method = "credentials"`, Terraform stores the secret access key in `terraform.tfstate` **in plaintext**. This is inherent to `aws_iam_access_key`, not something this configuration chose; marking the output `sensitive` hides it from console output but changes nothing about the file on disk.

So:

- `*.tfstate*` and `terraform.tfvars` are gitignored. Do not force-add them.
- Treat `terraform.tfstate` as a credential. If you'd shred a printout of the key, shred the state too.
- Don't put this state in a shared S3 backend without encryption and tight bucket policy — you'd be publishing a key that can read your whole account.

Two ways to avoid the problem entirely:

**Create the user without a key**, then make the key by hand in the console:

```hcl
create_access_key = false
```

**Or use role assumption**, where no long-lived secret exists to leak:

```hcl
auth_method            = "role"
trusted_principal_arns = ["arn:aws:iam::123456789012:user/you"]
external_id            = "…"   # openssl rand -hex 16
```

## What gets created

Both modes attach the same three policies:

| Policy | Source | Why |
| --- | --- | --- |
| `SecurityAudit` | AWS managed | Read access to security configuration |
| `ViewOnlyAccess` | AWS managed (`job-function/` path) | Broad list/describe coverage |
| `<name>-additions` | This repo | Permissions a few checks need that the first two don't grant |

The additions policy is vendored at [`terraform/policies/prowler-additions-policy.json`](../terraform/policies/prowler-additions-policy.json), copied verbatim from `permissions/prowler-additions-policy.json` at the pinned release (5.38.0). **Re-fetch it after `make upgrade`** — the action list grows as checks are added:

```bash
V=$(cat .prowler-version)
curl -sfL "https://raw.githubusercontent.com/prowler-cloud/prowler/refs/tags/$V/permissions/prowler-additions-policy.json" \
  -o terraform/policies/prowler-additions-policy.json
make tf-plan
```

Set `attach_additions_policy = false` to skip it. Those checks then report as errors rather than pass/fail — a coverage gap, not a security gap. See [learn.md](learn.md#reading-your-first-scan-without-panicking).

## Notable choices

**Everything is read-only.** No statement in any attached policy grants a write action. The optional `permissions_boundary` variable lets you enforce that structurally, so the identity can't gain write access even if someone attaches a broader policy later.

**`force_destroy = false` on the user.** If someone attaches extra policies or a second access key out of band, `terraform destroy` fails rather than silently discarding access paths Terraform didn't create. You'll have to look at what's there, which is the correct outcome.

**Partition-aware policy ARNs.** Built from `data.aws_partition.current` rather than hardcoding `arn:aws:`, so the managed-policy ARNs resolve in GovCloud and China too.

**A precondition on the role.** Role mode with an empty `trusted_principal_arns` renders a trust policy of `"Principal": {"AWS": []}` — which Terraform builds without complaint and AWS rejects at apply time with an opaque `MalformedPolicyDocument`. I verified that behavior directly. The precondition turns it into a clear plan-time message instead.

**`path = "/security/"`.** Groups these identities under a distinct IAM path so they're easy to find and easy to scope a boundary or SCP to later. It does not affect permissions.

**`region` only picks the API endpoint.** IAM is global. It does not limit what Prowler scans — a scan covers all regions regardless.

## Layout

```
terraform/
├── versions.tf                 provider + version constraints
├── variables.tf                all inputs, with validation
├── main.tf                     locals, data sources, additions policy
├── iam_user.tf                 auth_method = "credentials"
├── iam_role.tf                 auth_method = "role"
├── outputs.tf                  values for the Prowler UI
├── policies/                   vendored upstream policy JSON
├── terraform.tfvars.example    copy to terraform.tfvars
└── .terraform.lock.hcl         committed — pins provider versions
```

## Cleanup, in order

1. `make tf-destroy` — removes the IAM user, its access key, and the policies.
2. `make purge` — removes Prowler's stored (now-dead) encrypted copy of the key.
3. Delete `terraform/terraform.tfstate*` if you used `credentials` mode, since the secret is in it.

Step 1 alone is enough to revoke access. Steps 2 and 3 are about not leaving copies of a dead secret lying around. Tracked as [SEC-3](issue.md#sec-3--deleting-the-aws-key-doesnt-remove-it-from-prowler--open).

## Verification status

`terraform fmt`, `terraform init` and `terraform validate` pass. Both modes have been planned against a live account:

| Check | Result |
| --- | --- |
| `credentials` mode plan | 6 to add — user, access key, additions policy, 3 attachments |
| `role` mode plan (valid principal) | 5 to add, `sts:ExternalId` condition rendered correctly |
| `role` mode with empty `trusted_principal_arns` | Precondition fires at plan time with the intended message |
| Both AWS-managed policy ARNs resolve | Yes, including the `job-function/` path |
| `terraform apply` (credentials mode) | 6 added, 0 changed, 0 destroyed |
| Created user matches intent | Path `/security/`, 3 policies attached, 1 active key, **no** login profile |
| New key authenticates | `sts:GetCallerIdentity` returns the `prowler-scan` ARN |
| New key can read | `s3api list-buckets` succeeds |
| New key **cannot** write | `iam:CreateUser` returns `AccessDenied` — as it must |

Everything in this configuration has now been exercised against a live account.
