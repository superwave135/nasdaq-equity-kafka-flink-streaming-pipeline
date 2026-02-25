###############################################################################
# Dev Environment — terraform.tfvars
# Copy to terraform.tfvars and fill in your values before running
###############################################################################

aws_region   = "ap-southeast-1"
project_name = "stock-streaming"
environment  = "dev"
owner        = "your-github-username"   # <-- update

# Networking
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["ap-southeast-1a", "ap-southeast-1b"]

# Alerts — add your email to receive anomaly notifications
alert_emails = ["your-email@example.com"]   # <-- update

# GitHub OIDC for CI/CD (no long-lived AWS credentials in GitHub Actions)
github_org  = "your-github-username"   # <-- update
github_repo = "nasdaq-stock-streaming-pipeline"
