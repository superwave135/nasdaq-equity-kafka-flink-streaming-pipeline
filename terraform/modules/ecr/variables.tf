###############################################################################
# Variables — ECR Module
###############################################################################

variable "name_prefix" {
  description = "Resource name prefix (project-environment)"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod)"
  type        = string
}

variable "repositories" {
  description = "List of ECR repository short names (e.g. kafka, flink-jobmanager)"
  type        = list(string)
}
