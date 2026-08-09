data "aws_caller_identity" "current" {}

# Partition-aware so the managed-policy ARNs resolve in GovCloud and China too,
# where the "aws" partition string doesn't apply.
data "aws_partition" "current" {}

locals {
  use_user = var.auth_method == "credentials"
  use_role = var.auth_method == "role"

  partition = data.aws_partition.current.partition

  # Whether an external ID was supplied is not itself a secret; unwrapping just
  # the boolean keeps the guidance output from being marked sensitive wholesale.
  has_external_id = nonsensitive(var.external_id != "")

  # The two AWS-managed policies Prowler documents. Together they grant read-only
  # visibility account-wide and nothing else. ViewOnlyAccess lives under the
  # job-function path, which is easy to get wrong by hand.
  managed_policy_arns = [
    "arn:${local.partition}:iam::aws:policy/SecurityAudit",
    "arn:${local.partition}:iam::aws:policy/job-function/ViewOnlyAccess",
  ]

  tags = merge(
    {
      Name      = var.name
      ManagedBy = "terraform"
      Purpose   = "prowler-security-scanning"
    },
    var.tags,
  )
}

# Prowler's supplementary read-only permissions, vendored from the pinned release:
#   permissions/prowler-additions-policy.json @ 5.38.0
# Re-fetch it after `make upgrade` — the action list grows as checks are added.
resource "aws_iam_policy" "additions" {
  count = var.attach_additions_policy ? 1 : 0

  name        = "${var.name}-additions"
  description = "Supplementary read-only permissions required by Prowler checks not covered by SecurityAudit or ViewOnlyAccess."
  policy      = file("${path.module}/policies/prowler-additions-policy.json")
}
