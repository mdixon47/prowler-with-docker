# auth_method = "role"
#
# A role for Prowler to assume. Nothing long-lived is created, so no secret ever
# reaches Terraform state or Prowler's database. This is the recommended setup
# for anything beyond a one-off learning scan.

data "aws_iam_policy_document" "assume_role" {
  count = local.use_role ? 1 : 0

  statement {
    sid     = "AllowProwlerToAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }

    # Guards the confused-deputy problem: a third party holding the role ARN
    # still cannot assume it without knowing this value.
    dynamic "condition" {
      for_each = var.external_id != "" ? [var.external_id] : []

      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [condition.value]
      }
    }
  }
}

resource "aws_iam_role" "prowler" {
  count = local.use_role ? 1 : 0

  name                 = var.name
  path                 = "/security/"
  description          = "Read-only role assumed by Prowler to scan this account."
  assume_role_policy   = data.aws_iam_policy_document.assume_role[0].json
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary

  # Caught at plan time. A role whose trust policy lists no principals is created
  # successfully and is silently useless — nothing can ever assume it.
  lifecycle {
    precondition {
      condition     = length(var.trusted_principal_arns) > 0
      error_message = "auth_method = \"role\" requires at least one entry in trusted_principal_arns, otherwise nothing can assume the role."
    }
  }
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = local.use_role ? toset(local.managed_policy_arns) : toset([])

  role       = aws_iam_role.prowler[0].name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "additions" {
  count = local.use_role && var.attach_additions_policy ? 1 : 0

  role       = aws_iam_role.prowler[0].name
  policy_arn = aws_iam_policy.additions[0].arn
}
