variable "region" {
  description = "Region used for API calls. IAM is global, so this only decides which endpoint Terraform talks to — it does not limit what Prowler scans."
  type        = string
  default     = "us-east-1"
}

variable "auth_method" {
  description = <<-EOT
    How Prowler will authenticate.

      "credentials" — create an IAM user with a long-lived access key. Matches the
                      walkthrough. Simplest, but the secret ends up in Terraform state.
      "role"        — create an IAM role for Prowler to assume. No long-lived secret
                      is created or stored. Recommended for anything ongoing.
  EOT
  type        = string
  default     = "credentials"

  validation {
    condition     = contains(["credentials", "role"], var.auth_method)
    error_message = "auth_method must be either \"credentials\" or \"role\"."
  }
}

variable "name" {
  description = "Base name for the created IAM user or role."
  type        = string
  default     = "prowler-scan"

  validation {
    condition     = can(regex("^[a-zA-Z0-9+=,.@_-]{1,64}$", var.name))
    error_message = "name must be a valid IAM entity name (letters, digits, and +=,.@_- up to 64 chars)."
  }
}

variable "create_access_key" {
  description = <<-EOT
    Create an access key for the IAM user (auth_method = "credentials" only).

    Set to false to create the user without a key and generate the key by hand in
    the console — that keeps the secret out of Terraform state entirely. See
    docs/terraform.md for the trade-off.
  EOT
  type        = bool
  default     = true
}

variable "attach_additions_policy" {
  description = <<-EOT
    Attach Prowler's supplementary read-only policy alongside SecurityAudit and
    ViewOnlyAccess. Without it, a small number of checks report as errors rather
    than pass/fail because the two AWS-managed policies don't cover them.
  EOT
  type        = bool
  default     = true
}

variable "trusted_principal_arns" {
  description = <<-EOT
    Principals allowed to assume the Prowler role (auth_method = "role" only).

    Typically your own IAM user or role ARN, e.g.
      ["arn:aws:iam::123456789012:user/malik"]
    Use the account root ARN only if you understand that it delegates the decision
    to that account's own IAM policies.
  EOT
  type        = list(string)
  default     = []
}

variable "external_id" {
  description = <<-EOT
    External ID required when assuming the role (auth_method = "role" only).

    Guards against the confused-deputy problem. Generate one with:
      openssl rand -hex 16
    Leave empty to omit the condition — acceptable when the trusted principal is
    inside your own account, but set it if anything outside the account assumes it.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "max_session_duration" {
  description = "Maximum assumed-role session length in seconds (auth_method = \"role\"). A full scan can run 30+ minutes, so keep this comfortably above that."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200 seconds."
  }
}

variable "permissions_boundary" {
  description = "Optional permissions boundary ARN to attach to the created identity. Belt-and-braces guarantee that the scanner can never gain write access, even if a broader policy is attached later by mistake."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags applied to every created resource."
  type        = map(string)
  default     = {}
}
