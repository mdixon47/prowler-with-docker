# auth_method = "credentials"
#
# An IAM user with no console access and a long-lived access key. This is the
# path the walkthrough takes because it is the quickest to understand — but see
# the state-file warning in docs/terraform.md before running it.

resource "aws_iam_user" "prowler" {
  count = local.use_user ? 1 : 0

  # checkov:skip=CKV_AWS_273:An IAM user is the point of this mode. The scanner is
  # right that SSO/roles are better — that is what auth_method = "role" provides,
  # and what docs/terraform.md recommends. This path exists for the walkthrough.

  name                 = var.name
  path                 = "/security/"
  permissions_boundary = var.permissions_boundary

  # Deliberately NOT set. Destroying this user should fail if someone has
  # attached extra policies or keys out of band, so that Terraform doesn't
  # silently discard access paths it didn't create.
  force_destroy = false
}

resource "aws_iam_user_policy_attachment" "managed" {
  for_each = local.use_user ? toset(local.managed_policy_arns) : toset([])

  # checkov:skip=CKV_AWS_40:Attaching to a group would add indirection for a single
  # scanner identity with no privilege-accumulation risk — every attached policy is
  # read-only. Use auth_method = "role" to avoid users entirely.

  user       = aws_iam_user.prowler[0].name
  policy_arn = each.value
}

resource "aws_iam_user_policy_attachment" "additions" {
  count = local.use_user && var.attach_additions_policy ? 1 : 0

  # checkov:skip=CKV_AWS_40:Same rationale as the managed attachment above.

  user       = aws_iam_user.prowler[0].name
  policy_arn = aws_iam_policy.additions[0].arn
}

# WARNING: the secret is stored in Terraform state in plaintext. Protect the
# state file as you would the key itself, or set create_access_key = false and
# create the key in the console instead.
resource "aws_iam_access_key" "prowler" {
  count = local.use_user && var.create_access_key ? 1 : 0

  user   = aws_iam_user.prowler[0].name
  status = "Active"
}
