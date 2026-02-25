###############################################################################
# Outputs — GitHub OIDC Module
###############################################################################

output "role_arn" {
  description = "IAM role ARN for GitHub Actions to assume"
  value       = aws_iam_role.github_actions.arn
}
