###############################################################################
# Variables — Glue Module
###############################################################################

variable "name_prefix"          { type = string }
variable "environment"          { type = string }
variable "glue_role_arn"        { type = string }
variable "s3_processed_bucket"  { type = string }
variable "s3_curated_bucket"    { type = string }
variable "s3_scripts_bucket"    { type = string }
variable "glue_database"        { type = string }
