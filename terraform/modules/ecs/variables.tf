###############################################################################
# Variables — ECS Cluster Module
###############################################################################

variable "name_prefix" {
  description = "Resource name prefix (project-environment)"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod)"
  type        = string
}
