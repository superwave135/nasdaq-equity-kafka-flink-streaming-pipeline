###############################################################################
# Variables — Lambda Module
###############################################################################

variable "name_prefix"         { type = string }
variable "function_name"       { type = string }
variable "environment"         { type = string }
variable "lambda_role_arn"     { type = string }
variable "timeout"             { type = number }
variable "source_dir"          { type = string }
variable "dynamodb_table_name" { type = string }
variable "private_subnet_ids"  { type = list(string) }
variable "security_group_ids"  { type = list(string) }

variable "memory_size" {
  type    = number
  default = 256
}

variable "extra_env_vars" {
  description = "Additional environment variables specific to this function"
  type        = map(string)
  default     = {}
}

variable "allow_recursive_loop" {
  description = "Allow recursive self-invocation (needed for producer tick loop)"
  type        = bool
  default     = false
}
