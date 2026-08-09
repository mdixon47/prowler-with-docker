output "aws_account_id" {
  description = "The 12-digit account ID to enter when adding the provider in the Prowler UI."
  value       = data.aws_caller_identity.current.account_id
}

output "auth_method" {
  description = "Which authentication path this configuration created."
  value       = var.auth_method
}

# ---------- auth_method = "credentials" ----------

output "access_key_id" {
  description = "Access key ID to paste into the Prowler UI. Null unless auth_method = \"credentials\" and create_access_key = true."
  value       = try(aws_iam_access_key.prowler[0].id, null)
}

output "secret_access_key" {
  description = "Secret access key to paste into the Prowler UI. Read it with: terraform output -raw secret_access_key"
  value       = try(aws_iam_access_key.prowler[0].secret, null)
  sensitive   = true
}

output "user_arn" {
  description = "ARN of the created IAM user, if any."
  value       = try(aws_iam_user.prowler[0].arn, null)
}

# ---------- auth_method = "role" ----------

output "role_arn" {
  description = "ARN of the created role. Enter this in the Prowler UI when choosing Assumed Role."
  value       = try(aws_iam_role.prowler[0].arn, null)
}

# ---------- guidance ----------

output "next_steps" {
  description = "What to do with these values."
  value = local.use_user ? trimspace(<<-EOT
    Account ID:     ${data.aws_caller_identity.current.account_id}
    Access key ID:  ${try(aws_iam_access_key.prowler[0].id, "(not created — create_access_key = false)")}
    Secret:         terraform output -raw secret_access_key

    In the Prowler UI (http://localhost:3000):
      Settings -> Providers -> Add Provider -> Amazon Web Services
      Authentication: Credentials
      Leave the session token blank.

    The secret is in terraform.tfstate in plaintext. When you are done scanning,
    run `terraform destroy` to delete the key and user — see docs/terraform.md.
  EOT
    ) : trimspace(<<-EOT
    Account ID:  ${data.aws_caller_identity.current.account_id}
    Role ARN:    ${try(aws_iam_role.prowler[0].arn, "(none)")}
    External ID: ${local.has_external_id ? "set — read it with: terraform output -raw external_id_reminder" : "(not set)"}

    In the Prowler UI (http://localhost:3000):
      Settings -> Providers -> Add Provider -> Amazon Web Services
      Authentication: Assumed Role, then supply the role ARN above.

    No long-lived secret was created, so nothing sensitive is in Terraform state.
  EOT
  )
}

output "external_id_reminder" {
  description = "Echo of the external ID, so you can retrieve it without re-reading your tfvars."
  value       = local.has_external_id ? var.external_id : null
  sensitive   = true
}
