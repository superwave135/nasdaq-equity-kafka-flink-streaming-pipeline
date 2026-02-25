###############################################################################
# GitHub OIDC — IAM Role for GitHub Actions CI/CD
# No long-lived AWS credentials stored in GitHub
###############################################################################

# ── OIDC Provider (only one per account — import existing if present) ──
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ── IAM Role assumed by GitHub Actions ───────────────────────────────────
resource "aws_iam_role" "github_actions" {
  name = "${var.name_prefix}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })
}

# ── Permissions: deploy Terraform, push to ECR, update Lambda ────────────
resource "aws_iam_role_policy_attachment" "github_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  # Scoped down in production; AdministratorAccess is acceptable for
  # a single-developer portfolio project where the role is already
  # restricted to a single GitHub repo via OIDC conditions above.
}
