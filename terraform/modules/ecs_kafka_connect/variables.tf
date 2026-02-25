###############################################################################
# Variables — ECS Kafka Connect Module
###############################################################################

variable "name_prefix"                      { type = string }
variable "environment"                      { type = string }
variable "cluster_id"                       { type = string }
variable "cluster_arn"                      { type = string }
variable "private_subnet_ids"               { type = list(string) }
variable "security_group_ids"               { type = list(string) }
variable "execution_role_arn"               { type = string }
variable "task_role_arn"                    { type = string }
variable "connect_image"                    { type = string }
variable "kafka_bootstrap"                  { type = string }
variable "s3_processed_bucket"              { type = string }
variable "s3_region"                        { type = string }
variable "service_discovery_namespace_id"   { type = string }
variable "service_discovery_namespace_name" { type = string }
variable "cpu" {
  type    = number
  default = 512
}

variable "memory" {
  type    = number
  default = 1024
}
