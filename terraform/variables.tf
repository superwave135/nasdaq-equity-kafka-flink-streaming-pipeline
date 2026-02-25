###############################################################################
# Variables — stock-streaming-pipeline
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Project name used as prefix for all resource names"
  type        = string
  default     = "stock-streaming"
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod)"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag for all resources (e.g. GitHub username)"
  type        = string
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to create subnets in"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

# ── Alerting ──────────────────────────────────────────────────────────────────

variable "alert_emails" {
  description = "List of email addresses to receive SNS anomaly alerts"
  type        = list(string)
  default     = []
}

# ── GitHub OIDC (CI/CD) ───────────────────────────────────────────────────────

variable "github_org" {
  description = "GitHub organisation or username"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "nasdaq-stock-streaming-pipeline"
}
