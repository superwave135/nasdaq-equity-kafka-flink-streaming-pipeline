###############################################################################
# Variables — S3 Module
###############################################################################

variable "name_prefix" {
  description = "Resource name prefix (project-environment)"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "account_id" {
  description = "AWS account ID (used for globally unique bucket names)"
  type        = string
}
