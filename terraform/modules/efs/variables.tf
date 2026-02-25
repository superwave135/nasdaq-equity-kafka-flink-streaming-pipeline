###############################################################################
# Variables — EFS Module
###############################################################################

variable "name_prefix" {
  description = "Resource name prefix (project-environment)"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for mount targets"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for mount targets"
  type        = list(string)
}
