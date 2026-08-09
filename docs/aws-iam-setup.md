# Creating read-only AWS credentials for Prowler

Prowler needs credentials that can *describe* and *list* resources across your account. It never needs write access.

> ⚠️ Only do this in an AWS account you own or are explicitly authorized to assess.

> **Prefer to automate this?** [`terraform/`](../terraform) creates exactly what this page describes — user, policies, access key — and tears it down again with one command. See [terraform.md](terraform.md). Doing it by hand once first is still worth it; you'll recognize what the Terraform is doing.

## 1. Note your account ID

Log in to the [AWS Console](https://console.aws.amazon.com) and copy the **12-digit account ID** from the top-right account menu. Prowler asks for it when you add the provider.

## 2. Create the IAM user

**IAM → Users → Create user**

- Name: `prowler-scan`
- **Do not** enable console access — this identity only ever uses API keys.

## 3. Attach permissions

On the permissions step choose **Attach policies directly** and attach both AWS-managed policies:

| Policy | Why |
| --- | --- |
| `SecurityAudit` | Read access to security configuration across services |
| `ViewOnlyAccess` | Broad list/describe coverage (found under "Job function" policies) |

Together these give read-only visibility account-wide.

**Optional:** a small number of checks need permissions outside both policies (some DynamoDB, ECR, and Lambda calls). For full coverage, also attach Prowler's [`prowler-additions-policy.json`](https://github.com/prowler-cloud/prowler/blob/master/permissions/prowler-additions-policy.json) as a customer-managed policy. Not required for a first scan — without it those checks simply report as errors rather than pass/fail.

## 4. Create the access key

Open the user → **Security credentials → Create access key**.

- Use case: **Third-party service** (or "Other")
- Acknowledge the recommendation notice
- Copy the **Access key ID** and **Secret access key**

The secret is displayed **once**. If you lose it, delete the key and create a new one.

## 5. Verify (optional)

If you have the AWS CLI, confirm the key works and identifies the right account before pasting it into Prowler:

```bash
AWS_ACCESS_KEY_ID=AKIA... \
AWS_SECRET_ACCESS_KEY=... \
aws sts get-caller-identity
```

The `Account` field should match the ID from step 1, and `Arn` should end in `user/prowler-scan`.

## Handling the keys

- Never commit them. This repo's `.gitignore` covers `.env`, `credentials` and `.aws/`, but the safest place for the keys is your password manager and the Prowler UI field — nowhere else on disk.
- Prowler stores the secret encrypted in postgres using `DJANGO_SECRETS_ENCRYPTION_KEY` from `.env`. Run `make secrets` **before** saving the provider so that key isn't the published default.
- Treat a leaked key as a full read of your account: enumerable resource names, network layout, IAM structure.

## Cleanup

Do this when you're finished exploring, even if you leave Prowler running.

1. **IAM → Users → `prowler-scan` → Security credentials**
2. **Deactivate** the access key, then **Delete** it.
3. If you don't plan to scan again soon, delete the `prowler-scan` user entirely — it's a two-minute job to recreate.

Deleting the key does not remove it from Prowler's database. Either update the provider with a new key next time, or run `make purge` to drop the stored copy along with the rest of the local data.

## Next step: role assumption

Static keys are a learning shortcut. For ongoing use, create an IAM role with the same two policies, a trust policy allowing your own principal to assume it, and select **Assumed Role** instead of **Credentials** when adding the provider. Nothing long-lived is then stored by Prowler.
