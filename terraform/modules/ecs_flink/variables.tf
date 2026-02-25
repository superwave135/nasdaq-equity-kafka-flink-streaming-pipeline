###############################################################################
# Variables — ECS Flink Module (shared for jobmanager + taskmanager)
###############################################################################

variable "name_prefix"                      { type = string }
variable "environment"                      { type = string }
variable "role"                             { type = string }  # "jobmanager" or "taskmanager"
variable "cluster_id"                       { type = string }
variable "cluster_arn"                      { type = string }
variable "private_subnet_ids"               { type = list(string) }
variable "security_group_ids"               { type = list(string) }
variable "execution_role_arn"               { type = string }
variable "task_role_arn"                    { type = string }
variable "flink_image"                      { type = string }
variable "kafka_bootstrap"                  { type = string }
variable "service_discovery_namespace_id"   { type = string }
variable "service_discovery_namespace_name" { type = string }
variable "cpu"                              { type = number }
variable "memory"                           { type = number }

variable "jobmanager_host" {
  description = "JobManager service discovery endpoint (only needed for taskmanager role)"
  type        = string
  default     = ""
}
